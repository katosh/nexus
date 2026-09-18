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

PASS=0; FAIL=0; SKIP=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
# A SKIP is an assertion that was NOT MEASURED on this host. It is printed on
# stderr, counted in the assertion total (so the count guard cannot certify
# its loss), and named in the verdict line — never folded into PASS
# (your-org/nexus-code#1477: the non-hermetic arm below is the one case that
# legitimately cannot run where there is no Claude Code home).
skip() { printf '  SKIP: %s\n' "$1" >&2; SKIP=$(( SKIP + 1 )); }

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
# HERMETIC on the #1431 axis (your-org/nexus-code#1452). Several cases below run
# the guard with NEXUS_ROOT pointing at THIS checkout, and on a host where
# `sandbox-notify` resolves (the notifywrap shim, live on every operator's
# primary) the guard's refusal/carve-out path calls it — and it roots its
# decision ledger at `${NEXUS_NOTIFY_STATE_DIR:-$NEXUS_ROOT/monitor/.state}`,
# i.e. writes `monitor/.state/notify-decisions.jsonl` INTO THE CHECKOUT.
# Measured LEAK-AT-SOURCE under `nexus-root-sensitivity.sh probe` on this
# host and hermetic on CI (no shim there), which is why it survived: the
# write is real where the tests are run and invisible where they are gated.
# Pinned ONCE for every child; no case asserts on the ledger's location.
export NEXUS_NOTIFY_STATE_DIR="$SB/notify-state"
mkdir -p "$NEXUS_NOTIFY_STATE_DIR"
# A native-compinit ~/.zshrc dumps to $ZDOTDIR/.zcompdump; the positive case
# uses the repo shellenv as ZDOTDIR, so clean any dump the probe leaves (it is
# gitignored at runtime — this keeps the test tree pristine).
trap 'rm -rf "$SB"; rm -f "$REPO_ROOT/monitor/shellenv/.zcompdump"*' EXIT

# ---------------------------------------------------------------------------
# The FROZEN-SNAPSHOT surface (your-org/nexus-code#652/#654).
#
# The guard now also examines the Claude Code shell snapshot — the frozen
# artifact an agent's Bash tool SOURCES, as opposed to the fresh shell
# every case below spawns. `NEXUS_CC_HOME` is the exclusive seam for it.
#
# Exported once here so every pre-existing case sees a CLEAN snapshot and
# the new leg is a no-op for them. That is scoping, not silencing: those
# cases assert about the live-shell surface and were written before this
# one existed, and the snapshot leg gets its OWN cases at the end of this
# file. Without the seam they would read the REAL host's snapshot from
# inside a synthetic fixture — which is exactly the class of mistake this
# guard is about.
_mk_snapshot() {  # _mk_snapshot <cc-home> <path-value>
    mkdir -p "$1/shell-snapshots"
    printf 'export PATH=%s\n' "$2" > "$1/shell-snapshots/snapshot-zsh-1-test.sh"
}
# The shared snapshot deliberately contains NO guarded binary, so the leg
# finds nothing to resolve and is a true no-op. A snapshot listing the
# REPO's shim dirs would be wrong here: each case below builds its OWN
# synthetic shim dirs, so a repo-rooted "good" snapshot resolves outside
# them and refuses — a fixture that tests a different tree than the case
# configured.
CC_NEUTRAL="$SB/cc-neutral"; mkdir -p "$SB/empty-bin"
_mk_snapshot "$CC_NEUTRAL" "$SB/empty-bin"
export NEXUS_CC_HOME="$CC_NEUTRAL"

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
# Case 4b — SELF-PREFIXING ALIAS is transparent, and must NOT wedge the board
# (your-org/nexus-code#892, skeptic F1).
#
# An alias whose expansion's FIRST WORD is the alias name itself
# (`tmux='tmux -2'`, `ls='ls --color=auto'` — the commonest shape in any
# operator's rc) does not bypass a PATH-front shim: zsh will not recursively
# re-expand the head, so it resolves through PATH to the shim and only the extra
# flags are prepended. Measured on this host with the alias live: the aliased
# kill reached the shim and was REFUSED.
#
# Refusing it is not a harmless over-refusal — every agent launcher runs this
# gate and aborts on non-zero, so ONE alias in ~/.zshrc halts the entire board.
# That is the outcome this guard exists to prevent, arriving through the guard.
# ---------------------------------------------------------------------------
if [[ $HAVE_ZSH -eq 1 ]]; then
    SH4B="$SB/shims4b"; GW4B="$SH4B/ghwrap"; SE4B="$SB/shellenv4b"
    mkdir -p "$GW4B" "$SE4B"
    printf '#!/bin/sh\necho WRAP\n' > "$GW4B/gh"; chmod +x "$GW4B/gh"
    printf 'export PATH="%s:$PATH"\n' "$GW4B" > "$SE4B/.zshenv"
    { printf 'export PATH="%s:$PATH"\n' "$GW4B"
      printf "alias gh='gh --paginate'\n"; } > "$SE4B/.zshrc"
    out=$(HOME="$SB/emptyhome" NEXUS_ROOT="$SB" ZDOTDIR="$SE4B" \
          NEXUS_SHIMWRAP_GLOB="$SH4B/*wrap" \
          NEXUS_ASSERT_GH_SHELL="$ZSH_BIN" SHELL="$ZSH_BIN" \
          NEXUS_ASSERT_SKIP_NPROC=1 \
          "$ASSERT" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "self-prefixing alias: allows the spawn (does not wedge the board)"
    else
        bad "self-prefixing alias" "expected exit 0, got $rc; output: $out"
    fi
    if grep -qi 'SELF-PREFIXING' <<<"$out"; then
        ok "self-prefixing alias: says so, rather than passing silently"
    else
        bad "self-prefixing alias note" "no NOTE naming it; output: $out"
    fi

    # NEGATIVE CONTROL — the distinction has to be the HEAD WORD, not merely
    # "an alias exists". An alias whose first word DIFFERS genuinely bypasses
    # the shim and must still refuse, or 4b has simply disabled case 4.
    SE4C="$SB/shellenv4c"; mkdir -p "$SE4C"
    printf 'export PATH="%s:$PATH"\n' "$GW4B" > "$SE4C/.zshenv"
    { printf 'export PATH="%s:$PATH"\n' "$GW4B"
      printf "alias gh='/usr/bin/gh --paginate'\n"; } > "$SE4C/.zshrc"
    out=$(HOME="$SB/emptyhome" NEXUS_ROOT="$SB" ZDOTDIR="$SE4C" \
          NEXUS_SHIMWRAP_GLOB="$SH4B/*wrap" \
          NEXUS_ASSERT_GH_SHELL="$ZSH_BIN" SHELL="$ZSH_BIN" \
          NEXUS_ASSERT_SKIP_NPROC=1 \
          "$ASSERT" 2>&1); rc=$?
    if [[ $rc -eq 1 ]] && grep -qi 'SHADOWED' <<<"$out"; then
        ok "CONTROL: an alias with a DIFFERENT head still refuses"
    else
        bad "CONTROL different-head alias" "expected exit 1 naming SHADOWED, got $rc; output: $out"
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
# Runtime state and other checkouts are excluded: they are not part of the
# checkout's SHAPE, and on a live primary `monitor/.state` alone held ~21.8k
# files — enough that this copy ran past a 900 s wrapper and the suite ended
# with an injected 124 and no verdict line (your-org/nexus-code#1477).
if ( cd "$REPO_ROOT" && tar --exclude=./.git --exclude=./monitor/.state --exclude=./work --exclude=./reports --exclude=./node_modules --exclude=./locals -cf - . ) 2>/dev/null | ( cd "$DENSE" && tar xf - ) 2>/dev/null \
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
# Case 8 — THE NEGATIVE CONTROL your-org/nexus-code#652 and #654 BOTH DEMAND:
# "a fixture where the probe shell is wrapped and the snapshot shell is not
# must make the guard FAIL."
#
# This is the shape that was filed. In a live worker, `assert-shims-wrapped.sh`
# exited 0 while that same shell's `command -v pip` answered `/app/bin/pip` —
# the #487 fork-storm binary. The guard was not careless: every shell it could
# spawn had genuinely been repaired by the front-path fix, and the one that had
# not was the CALLER's, which no spawned probe can reach.
#
# The fixture inverts nothing and stubs nothing. The probe surfaces get a
# WRAPPED PATH, so `-c` and `-lic` resolve the shim and report clean exactly as
# they did in July. The INHERITED PATH — what the caller exported, recorded by
# monitor/shellenv/bash_env.sh before it re-fronts — gets a decoy ahead of the
# still-present shim dir. That is the burial signature, and it is the property
# the ambient surface adjudicates on.
#
# TWO ARMS, and the second is what stops this passing vacuously. Arm A buries
# the inherited PATH and requires a REFUSAL. Arm B changes ONLY that one
# variable — same fixture, same probe shells, same shim set — and requires a
# PASS. Without arm B a refusal for any unrelated reason would satisfy arm A,
# and this suite has already been bitten once by a control that asserted an
# absence a different code path produced.
SH8="$SB/shims8"; DEC8="$SB/decoy8"
mkdir -p "$SH8/ghwrap" "$SH8/pipwrap" "$DEC8"
printf '#!/bin/sh\necho WRAP\n'  > "$SH8/ghwrap/gh";  chmod +x "$SH8/ghwrap/gh"
printf '#!/bin/sh\necho WRAP\n'  > "$SH8/pipwrap/pip"; chmod +x "$SH8/pipwrap/pip"
printf '#!/bin/sh\necho DECOY\n' > "$DEC8/gh";  chmod +x "$DEC8/gh"
printf '#!/bin/sh\necho DECOY\n' > "$DEC8/pip"; chmod +x "$DEC8/pip"
_p8_wrapped="$SH8/ghwrap:$SH8/pipwrap:/usr/bin:/bin"
_p8_buried="$DEC8:$_p8_wrapped"

# ARM A — caller BURIED, probe shells clean. Must REFUSE.
out=$(env -u BASH_ENV PATH="$_p8_wrapped" \
      NEXUS_INHERITED_PATH="$_p8_buried" \
      NEXUS_ROOT="$SB" NEXUS_SHIMWRAP_GLOB="$SH8/*wrap" \
      NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
      NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>&1); rc=$?
if [[ $rc -eq 1 ]]; then
    ok "#652/#654: a WRAPPED probe shell over a BURIED caller shell REFUSES"
else
    bad "#652/#654 negative control" "expected exit 1, got $rc; output: $out"
fi
if grep -q 'REFUSING SPAWN: ambient' <<<"$out"; then
    ok "#652/#654: the refusal names the AMBIENT surface"
else
    bad "#652/#654 surface" "refusal did not name the ambient surface; output: $out"
fi
# LOCALISATION — this is the assertion that proves the two surfaces genuinely
# disagree, i.e. that the pre-#652 guard would have passed this exact fixture.
if grep -q 'REFUSING SPAWN: .*non-interactive' <<<"$out"; then
    bad "#652/#654 localization" "the spawned -c surface ALSO refused, so this fixture does not exhibit the probe/caller disagreement it is named for; output: $out"
else
    ok "#652/#654: the spawned probe surfaces stay CLEAN — the disagreement is the finding"
fi
if grep -q 'REFUSING SPAWN: ambient.*`pip`' <<<"$out" && grep -q 'FAIL-OPEN' <<<"$out"; then
    ok "#652/#654: pip is enforced on the ambient surface too, with its FAIL-OPEN note (#487)"
else
    bad "#652/#654 pip" "no ambient pip refusal carrying the FAIL-OPEN rationale; output: $out"
fi

# ARM B — POSITIVE CONTROL. One variable changes: the caller is no longer
# buried. Everything else is byte-identical. Must PASS.
out=$(env -u BASH_ENV PATH="$_p8_wrapped" \
      NEXUS_INHERITED_PATH="$_p8_wrapped" \
      NEXUS_ROOT="$SB" NEXUS_SHIMWRAP_GLOB="$SH8/*wrap" \
      NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
      NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
    ok "#652/#654 CONTROL: unburying the caller — and nothing else — restores the pass"
else
    bad "#652/#654 control" "expected exit 0 with an unburied caller, got $rc; output: $out"
fi

# ARM C — the RESIDUAL, asserted rather than described. A caller PATH carrying
# no shim dir at all is not the burial signature and must NOT refuse: this guard
# runs in CI and in its own fixtures, where an unfronted caller is normal, and a
# refusal there would halt every spawn on the board. It is still SAID.
#
# The caller PATH here carries the DECOY but NOT the shim dirs, so the names
# resolve to a real off-shim binary. An UNRESOLVABLE name is a different
# adjudication (a missing command fails loudly on use) and would satisfy this
# arm for the wrong reason — the first draft did exactly that, and the arm
# caught it.
out=$(env -u BASH_ENV PATH="$_p8_wrapped" \
      NEXUS_INHERITED_PATH="$DEC8:/usr/bin:/bin" \
      NEXUS_ROOT="$SB" NEXUS_SHIMWRAP_GLOB="$SH8/*wrap" \
      NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
      NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q 'WARNING: ambient' <<<"$out" \
   && ! grep -q 'REFUSING SPAWN: ambient' <<<"$out"; then
    ok "#652/#654 RESIDUAL: an unfronted caller WARNS with its scope named, and does not refuse"
else
    bad "#652/#654 residual" "expected exit 0 with an ambient WARNING and no ambient refusal, got rc=$rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 9b — THE PRODUCER-TO-CONSUMER CHANNEL, one hop up (your-org/nexus-code#1383).
#
# Arms A-C above set NEXUS_INHERITED_PATH on the invocation line, so they
# exercise the CONSUMER and never the channel: the one hop where the value is
# destroyed — a bash launcher whose own prelude re-fronts BEFORE it exports
# PATH to the bash guard, whose own prelude then re-records the repaired
# value — was the one hop nothing covered. So this case runs the REAL chain:
# the repo's bash_env.sh as BASH_ENV, a fixture launcher that is a bash
# script, and the guard as its CHILD. Three arms, one variable each:
#
#   D  launcher inherits a BURIED PATH  -> guard WARNS one hop up, rc 0
#   E  same, but the launcher runs the guard through `timeout` (an exec
#      interposer breaks the pid chain)  -> NO warning, rc 0: the stated
#      residual, and the potency control that the pid chain is the mechanism
#   F  launcher inherits a CLEAN PATH   -> NO warning, rc 0
#
# The shim dirs live under the fixture NEXUS_ROOT because that is where the
# prelude fronts from; the decoy sits ahead of them in the buried PATH.
# ---------------------------------------------------------------------------
SB9="$SB/chain9"; DEC9="$SB9/decoy"
mkdir -p "$SB9/monitor/ghwrap" "$SB9/monitor/pipwrap" "$DEC9"
printf '#!/bin/sh\necho WRAP\n'  > "$SB9/monitor/ghwrap/gh";   chmod +x "$SB9/monitor/ghwrap/gh"
printf '#!/bin/sh\necho WRAP\n'  > "$SB9/monitor/pipwrap/pip"; chmod +x "$SB9/monitor/pipwrap/pip"
printf '#!/bin/sh\necho DECOY\n' > "$DEC9/gh";  chmod +x "$DEC9/gh"
printf '#!/bin/sh\necho DECOY\n' > "$DEC9/pip"; chmod +x "$DEC9/pip"
_p9_wrapped="$SB9/monitor/ghwrap:$SB9/monitor/pipwrap:/usr/bin:/bin"
_p9_buried="$DEC9:$_p9_wrapped"
# The launcher is a bash SCRIPT (so BASH_ENV runs in it) that runs the guard
# as a CHILD (so the guard's $PPID is the launcher — `exec` would collapse the
# two into one pid and there would be no hop to carry).
printf '#!/usr/bin/env bash\nbash "$1"\n' > "$SB9/launcher.sh"; chmod +x "$SB9/launcher.sh"
printf '#!/usr/bin/env bash\ntimeout 40 bash "$1"\n' > "$SB9/launcher-timeout.sh"; chmod +x "$SB9/launcher-timeout.sh"
_chain9() {  # _chain9 <launcher> <inherited-path>
    env -u NEXUS_PREV_BASH_ENV -u NEXUS_INHERITED_PATH -u NEXUS_INHERITED_PATH_PID \
        -u NEXUS_INHERITED_PATH_UPSTREAM -u NEXUS_INHERITED_PATH_UPSTREAM_PID \
        -u NEXUS_PATH_FRONT_OFF -u NEXUS_LOCALS \
        BASH_ENV="$REPO_ROOT/monitor/shellenv/bash_env.sh" PATH="$2" \
        NEXUS_ROOT="$SB9" NEXUS_SHIMWRAP_GLOB="$SB9/monitor/*wrap" \
        NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
        NEXUS_ASSERT_SKIP_NPROC=1 bash "$1" "$ASSERT" 2>&1
}
# ARM D — the channel, buried above the launcher. WARNING one hop up, no refusal.
out=$(_chain9 "$SB9/launcher.sh" "$_p9_buried"); rc=$?
if [[ $rc -eq 0 ]]; then
    ok "#1383 ARM D: a launcher chain over a BURIED shell exits 0 (warning, never a refusal)"
else
    bad "#1383 ARM D rc" "expected exit 0 through the launcher chain, got $rc; output: $out"
fi
if grep -q 'WARNING: ambient (one hop above the caller): `gh`' <<<"$out"; then
    ok "#1383 ARM D: the guard WARNS about the burial ONE HOP ABOVE its caller"
else
    bad "#1383 ARM D warning" "no one-hop-up warning for gh; output: $out"
fi
if grep -q 'NOTE: ambient: the caller (pid [0-9]*) had already run the nexus prelude' <<<"$out"; then
    ok "#1383 ARM D: …and says WHY the immediate ambient reading was not adjudicable (the caller re-fronted)"
else
    bad "#1383 ARM D note" "the not-adjudicable note is missing; output: $out"
fi
if grep -q 'REFUSING SPAWN: ambient' <<<"$out"; then
    bad "#1383 ARM D refusal" "the IMMEDIATE ambient surface refused — the launcher's prelude did not re-front, so this fixture is not the chain it claims to be; output: $out"
else
    ok "#1383 ARM D: the immediate ambient surface is CLEAN (the launcher's prelude repaired it) — the disagreement is the finding"
fi
# ARM E — POTENCY: an exec interposer between launcher and guard breaks the
# pid chain, so no upstream record reaches the guard and it stays silent. That
# is the documented residual, and it is also what proves ARM D's warning came
# from the pid-keyed carry and not from anything else in the environment.
out=$(_chain9 "$SB9/launcher-timeout.sh" "$_p9_buried"); rc=$?
if [[ $rc -eq 0 ]] && ! grep -q 'one hop above the caller' <<<"$out"; then
    ok "#1383 ARM E (POTENCY/RESIDUAL): with \`timeout\` between launcher and guard the pid chain breaks and NO upstream warning is possible"
else
    bad "#1383 ARM E" "expected exit 0 with no one-hop-up warning through an exec interposer, got rc=$rc; output: $out"
fi
# ARM F — CONTROL: the same chain with the launcher's own inherited PATH clean.
out=$(_chain9 "$SB9/launcher.sh" "$_p9_wrapped"); rc=$?
if [[ $rc -eq 0 ]] && ! grep -q 'WARNING: ambient (one hop above' <<<"$out"; then
    ok "#1383 ARM F CONTROL: an UNBURIED launcher chain — one variable — warns about nothing one hop up"
else
    bad "#1383 ARM F control" "expected exit 0 and no one-hop-up warning with a clean launcher PATH, got rc=$rc; output: $out"
fi
if grep -q 'NOTE: ambient: the caller' <<<"$out"; then
    ok "#1383 ARM F: …while still stating that the caller had re-fronted (the note is about adjudicability, not burial)"
else
    bad "#1383 ARM F note" "the re-fronted-caller note should print whenever an upstream record exists; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 10 — the FROZEN-SNAPSHOT surface (your-org/nexus-code#652 / #654).
#
# The whole point: every case above spawns a FRESH shell, where front-path
# runs last and wins, so the guard passes honestly. The agent's Bash tool
# instead SOURCES a snapshot frozen at Claude Code startup. Measured on
# this host 2026-08-02, that snapshot carried monitor/ghwrap at PATH
# position 13 — present, but behind linuxbrew — and the guard exited 0
# while three workers resolved `gh` and `pip` unwrapped.
#
# So these cases vary ONLY the snapshot, holding the live surface clean.
# ---------------------------------------------------------------------------
SNAP_SHIMS="$SB/snapshims"; mkdir -p "$SNAP_SHIMS/ghwrap" "$SNAP_SHIMS/pipwrap" "$SB/snapdecoy"
for _n in gh; do printf '#!/bin/sh\n:\n' > "$SNAP_SHIMS/ghwrap/$_n"; chmod +x "$SNAP_SHIMS/ghwrap/$_n"; done
for _n in pip pip3; do printf '#!/bin/sh\n:\n' > "$SNAP_SHIMS/pipwrap/$_n"; chmod +x "$SNAP_SHIMS/pipwrap/$_n"; done
for _n in gh pip pip3; do printf '#!/bin/sh\n:\n' > "$SB/snapdecoy/$_n"; chmod +x "$SB/snapdecoy/$_n"; done

# Sets SNAP_OUT and SNAP_RC as GLOBALS. Deliberately not `rc=$(_snap_run …)`:
# a command substitution runs in a subshell, so SNAP_OUT would never escape it.
_snap_run() {  # _snap_run <cc-home>
    SNAP_OUT=$(NEXUS_CC_HOME="$1" NEXUS_SHIMWRAP_GLOB="$SNAP_SHIMS/*" \
        NEXUS_ROOT="$REPO_ROOT" NEXUS_ASSERT_SKIP_NPROC=1 \
        NEXUS_ASSERT_GH_SHELL="$SB/no-such-shell-$$" \
        "$ASSERT" 2>&1)
    SNAP_RC=$?
}

# (a) shims FIRST in the frozen PATH → the leg must not object.
CC_OK="$SB/cc-ok"; _mk_snapshot "$CC_OK" "$SNAP_SHIMS/ghwrap:$SNAP_SHIMS/pipwrap:$SB/snapdecoy"
_snap_run "$CC_OK"
if [[ "$SNAP_OUT" != *"frozen tool-shell snapshot"* ]]; then
    ok "snapshot: shims ahead of the decoy → no objection from the snapshot leg"
else
    bad "snapshot ordering-good" "leg objected on a correctly-ordered snapshot: $SNAP_OUT"
fi

# (b) THE DEFECT: shims PRESENT but BEHIND the decoy → must REFUSE.
# Presence is not the property; ORDER is. A guard that greps for the shim
# dir would pass this, which is precisely how #652 survived.
CC_BAD="$SB/cc-bad"; _mk_snapshot "$CC_BAD" "$SB/snapdecoy:$SNAP_SHIMS/ghwrap:$SNAP_SHIMS/pipwrap"
_snap_run "$CC_BAD"
if [[ "$SNAP_RC" == "1" && "$SNAP_OUT" == *"frozen tool-shell snapshot resolves"* ]]; then
    ok "snapshot: shim dirs PRESENT but behind a decoy → REFUSES (order, not presence)"
else
    bad "snapshot ordering-bad" "expected refusal (rc=1), got rc=$SNAP_RC: $SNAP_OUT"
fi
if [[ "$SNAP_OUT" == *"$SB/snapdecoy/pip"* ]]; then
    ok "snapshot: names the fork-storm binary the tool shell would actually run (#487/#654)"
else
    bad "snapshot names pip" "refusal did not name the resolved pip: $SNAP_OUT"
fi

# (c) no snapshot at all → NOT CHECKED (79), never a pass. At spawn time
# the CHILD's snapshot does not exist yet, so silence here must not be
# read as health — that is the exact fail-open shape being fixed.
CC_NONE="$SB/cc-none"; mkdir -p "$CC_NONE"
_snap_run "$CC_NONE"
if [[ "$SNAP_RC" == "79" && "$SNAP_OUT" == *"no readable Claude Code shell snapshot"* ]]; then
    ok "snapshot: absent snapshot → NOT CHECKED (79), not a pass"
else
    bad "snapshot absent" "expected 79 + diagnostic, got rc=$SNAP_RC: $SNAP_OUT"
fi

# ---------------------------------------------------------------------------
# Case 11 — FOREIGN vs BURIAL, and the SELF-HEAL path (your-org/nexus-code#1477).
#
# The outage: the newest snapshot on the host had been written by a `claude`
# launched OUTSIDE the nexus launcher — no ZDOTDIR, so NO shim dir anywhere in
# its PATH — and the leg refused every spawn for 18 h, including _respawn.sh.
# Two signatures, two verdicts, and a path on which neither may refuse:
#
#   (a) FOREIGN + this spawn's live probes CLEAN   -> WARN, rc 0, never REFUSING
#   (b) FOREIGN + live probes did NOT run          -> NOT CHECKED (79), never 1
#   (c) BURIAL, worker path                        -> REFUSE (rc 1)  — the CONTROL:
#                                                     the #652/#654 protection is intact
#   (d) BURIAL, self-heal path (NEXUS_IS_ORCHESTRATOR=1)
#                                                  -> WARN + durable row, rc 0
#   (e) the SPAWNER-CARRIED route ranks above the mtime proxy, and is scoped by
#       NEXUS_CC_HOME like ancestry
#
# The live probes here RUN, so `_asw_live_clean` is an observation and not the
# absence of a refusal: the same chain fixture case 9b built (a bash launcher
# with the repo's bash_env.sh as BASH_ENV, fixture shim dirs under the fixture
# NEXUS_ROOT, the decoy ahead of them only where a case wants a burial).
# ---------------------------------------------------------------------------
# Snapshot homes. SB9's shim dirs are the ones the guard enumerates
# (NEXUS_SHIMWRAP_GLOB=$SB9/monitor/*wrap), DEC9 holds decoy gh/pip.
CC11_FOREIGN="$SB/cc11-foreign"; _mk_snapshot "$CC11_FOREIGN" "$DEC9:/usr/bin:/bin"
CC11_BURIED="$SB/cc11-buried";   _mk_snapshot "$CC11_BURIED"  "$DEC9:$SB9/monitor/ghwrap:$SB9/monitor/pipwrap:/usr/bin:/bin"
CC11_CLEAN="$SB/cc11-clean";     _mk_snapshot "$CC11_CLEAN"   "$SB9/monitor/ghwrap:$SB9/monitor/pipwrap:$DEC9:/usr/bin:/bin"
# Sets SNAP_OUT / SNAP_RC as globals (see _snap_run for why not `$(…)`).
_snap_live() {  # _snap_live <cc-home> [VAR=val …]  — live probes RUN and are clean
    SNAP_OUT=$(env -u NEXUS_PREV_BASH_ENV -u NEXUS_INHERITED_PATH -u NEXUS_INHERITED_PATH_PID \
        -u NEXUS_INHERITED_PATH_UPSTREAM -u NEXUS_INHERITED_PATH_UPSTREAM_PID \
        -u NEXUS_PATH_FRONT_OFF -u NEXUS_LOCALS -u NEXUS_IS_ORCHESTRATOR -u NEXUS_SPAWNER_SNAPSHOT \
        -u NEXUS_WORKER_WINDOW -u NEXUS_ORCHESTRATOR_WINDOW \
        BASH_ENV="$REPO_ROOT/monitor/shellenv/bash_env.sh" PATH="$_p9_wrapped" \
        NEXUS_ROOT="$SB9" NEXUS_SHIMWRAP_GLOB="$SB9/monitor/*wrap" \
        NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
        NEXUS_ASSERT_SKIP_NPROC=1 NEXUS_ASSERT_NO_ANCESTRY=1 NEXUS_CC_HOME="$1" "${@:2}" \
        bash "$ASSERT" 2>&1)
    SNAP_RC=$?
}

# (a) FOREIGN + live clean → WARNING, not a refusal. THE OUTAGE CONDITION.
_snap_live "$CC11_FOREIGN"
if [[ "$SNAP_RC" == "0" && "$SNAP_OUT" != *"REFUSING SPAWN"* ]]; then
    ok "#1477 (a): a FOREIGN snapshot (no shim dir at all) with this spawn's own shells clean → rc 0, no refusal"
else
    bad "#1477 (a) verdict" "expected rc 0 and no REFUSING on a foreign snapshot with live-clean probes, got rc=$SNAP_RC: $SNAP_OUT"
fi
if [[ "$SNAP_OUT" == *"READ AS FOREIGN"* && "$SNAP_OUT" == *"provenance: FOREIGN"* ]]; then
    ok "#1477 (a): …and it is SAID — read as foreign, provenance reported, not silently allowed"
else
    bad "#1477 (a) warning" "the foreign-artifact warning and provenance line are missing: $SNAP_OUT"
fi
if [[ "$SNAP_OUT" == *"foreign snapshot resolves \`pip\`"* ]]; then
    ok "#1477 (a): …naming the fork-storm binary the FOREIGN shell would run, so the reader sees what was not adjudicated"
else
    bad "#1477 (a) names" "the per-name foreign lines should still name pip: $SNAP_OUT"
fi

# (b) FOREIGN + live probes did NOT run (no probe shell) → NOT CHECKED, never 1.
# `_snap_run` is the case-10 driver: no probe shell, so the probe legs are
# NOT CHECKED and `_asw_live_clean` is EMPTY — an absence, not a clean.
_mk_snapshot "$SB/cc11-foreign-nolive" "$SB/snapdecoy"
_snap_run "$SB/cc11-foreign-nolive"
if [[ "$SNAP_RC" == "79" && "$SNAP_OUT" == *"NOT CHECKED"*"FOREIGN"* && "$SNAP_OUT" != *"REFUSING SPAWN"* ]]; then
    ok "#1477 (b): FOREIGN snapshot while the live probes did not run → NOT CHECKED (79): 'could not look' is neither a pass nor a refusal on a peer's artifact"
else
    bad "#1477 (b)" "expected 79 + a FOREIGN not-checked line and no refusal, got rc=$SNAP_RC: $SNAP_OUT"
fi

# (c) CONTROL — BURIAL on the worker path still REFUSES. Same fixture as (a),
# one variable: the shim dirs are IN the recorded PATH, behind the decoy.
_snap_live "$CC11_BURIED"
if [[ "$SNAP_RC" == "1" && "$SNAP_OUT" == *"REFUSING SPAWN: frozen tool-shell snapshot resolves"* && "$SNAP_OUT" == *"BURIAL signature"* ]]; then
    ok "#1477 (c) CONTROL: BURIAL (shim dirs present, decoy ahead) on the WORKER path still refuses — #652/#654 intact, and the diagnostic names the signature"
else
    bad "#1477 (c) control" "expected rc 1 + BURIAL refusal on the worker path, got rc=$SNAP_RC: $SNAP_OUT"
fi
if [[ "$SNAP_OUT" != *"READ AS FOREIGN"* ]]; then
    ok "#1477 (c) CONTROL: …and a burial is NOT misread as foreign"
else
    bad "#1477 (c) misread" "a snapshot WITH shim dirs was called foreign: $SNAP_OUT"
fi

# (d) BURIAL on the SELF-HEAL path → WARN + durable row, never a refusal.
rm -f "$SB9/monitor/.state/guard-unverified.log"
_snap_live "$CC11_BURIED" NEXUS_IS_ORCHESTRATOR=1 NEXUS_ORCHESTRATOR_WINDOW=test-orch
if [[ "$SNAP_RC" == "0" && "$SNAP_OUT" != *"REFUSING SPAWN"* && "$SNAP_OUT" == *"WARNING (self-heal path, NOT refusing)"* ]]; then
    ok "#1477 (d): the SAME burial with NEXUS_IS_ORCHESTRATOR=1 → rc 0 and a loud self-heal warning — the board can come back"
else
    bad "#1477 (d) verdict" "expected rc 0 + self-heal WARNING on the orchestrator path, got rc=$SNAP_RC: $SNAP_OUT"
fi
if [[ -s "$SB9/monitor/.state/guard-unverified.log" ]] \
   && grep -q $'\tassert-shims-wrapped\ttest-orch\tfrozen-snapshot leg: BURIAL signature' "$SB9/monitor/.state/guard-unverified.log" \
   && [[ $(wc -l < "$SB9/monitor/.state/guard-unverified.log") -eq 1 ]]; then
    ok "#1477 (d): …and the announce-and-proceed is DURABLE — ONE row in monitor/.state/guard-unverified.log names the leg, the window and the signature"
else
    bad "#1477 (d) durable row" "no guard-unverified.log row for the self-heal allow; log: $(cat "$SB9/monitor/.state/guard-unverified.log" 2>/dev/null)"
fi
# A NON-"1" marker must NOT enable the self-heal rule (the same reading every
# other consumer of NEXUS_IS_ORCHESTRATOR applies) — the permissive default
# arm is the failure this file exists to refuse.
_snap_live "$CC11_BURIED" NEXUS_IS_ORCHESTRATOR=yes
if [[ "$SNAP_RC" == "1" ]]; then
    ok "#1477 (d) NEGATIVE: NEXUS_IS_ORCHESTRATOR=yes is not the marker — the worker refusal stands (only the literal 1 enables)"
else
    bad "#1477 (d) negative" "a non-1 marker value enabled the self-heal rule (rc=$SNAP_RC)"
fi

# (e) SPAWNER-CARRIED selection. The CC home's NEWEST snapshot is CLEAN; the
# spawner's (carried) is BURIED and sits INSIDE that home → the carried one
# wins over the mtime proxy and refuses; moved OUTSIDE the seam → ignored.
_mk_snapshot "$CC11_CLEAN" "$SB9/monitor/ghwrap:$SB9/monitor/pipwrap:$DEC9:/usr/bin:/bin"   # newest by mtime
sleep 1; touch "$CC11_CLEAN/shell-snapshots/snapshot-zsh-1-test.sh"
cp "$CC11_BURIED/shell-snapshots/snapshot-zsh-1-test.sh" "$CC11_CLEAN/shell-snapshots/snapshot-zsh-0-spawner.sh"
touch -d '2000-01-01 00:00:00' "$CC11_CLEAN/shell-snapshots/snapshot-zsh-0-spawner.sh"
_snap_live "$CC11_CLEAN"
if [[ "$SNAP_RC" == "0" && "$SNAP_OUT" == *"selected via: newest in NEXUS_CC_HOME"* ]]; then
    ok "#1477 (e) baseline: without a carried snapshot the mtime proxy selects the newest (clean) one and passes"
else
    bad "#1477 (e) baseline" "expected the mtime route and rc 0, got rc=$SNAP_RC: $SNAP_OUT"
fi
_snap_live "$CC11_CLEAN" NEXUS_SPAWNER_SNAPSHOT="$CC11_CLEAN/shell-snapshots/snapshot-zsh-0-spawner.sh"
if [[ "$SNAP_RC" == "1" && "$SNAP_OUT" == *"selected via: the SPAWNING agent's own tool shell"* ]]; then
    ok "#1477 (e): a carried spawner snapshot outranks the mtime proxy — the OLDER, buried one is adjudicated and refuses, and the route is REPORTED"
else
    bad "#1477 (e) carried" "expected the spawner route to win and refuse (rc 1), got rc=$SNAP_RC: $SNAP_OUT"
fi
_snap_live "$CC11_CLEAN" NEXUS_SPAWNER_SNAPSHOT="$CC11_BURIED/shell-snapshots/snapshot-zsh-1-test.sh"
if [[ "$SNAP_RC" == "0" && "$SNAP_OUT" == *"lies outside NEXUS_CC_HOME"* && "$SNAP_OUT" == *"selected via: newest in NEXUS_CC_HOME"* ]]; then
    ok "#1477 (e) SCOPE: a carried snapshot OUTSIDE NEXUS_CC_HOME is ignored under the exclusive seam, not preferred — the same rule ancestry follows"
else
    bad "#1477 (e) scope" "expected the outside-seam carried path to be ignored and the mtime route used, got rc=$SNAP_RC: $SNAP_OUT"
fi

# (f) FOREIGN + this spawn's OWN env BURIED → the live legs refuse (rc 1) and
# the snapshot leg says it adds nothing. The forensics report stated this arm
# "by construction, not by measurement"; this is the measurement. The live
# burial is the case-9b shape: the decoy ahead of the shim dirs in the PATH the
# guard INHERITS (bash_env.sh records it before re-fronting).
SNAP_OUT=$(env -u NEXUS_PREV_BASH_ENV -u NEXUS_INHERITED_PATH -u NEXUS_INHERITED_PATH_PID \
    -u NEXUS_INHERITED_PATH_UPSTREAM -u NEXUS_INHERITED_PATH_UPSTREAM_PID \
    -u NEXUS_PATH_FRONT_OFF -u NEXUS_LOCALS -u NEXUS_IS_ORCHESTRATOR -u NEXUS_SPAWNER_SNAPSHOT \
    -u NEXUS_WORKER_WINDOW -u NEXUS_ORCHESTRATOR_WINDOW \
    BASH_ENV="$REPO_ROOT/monitor/shellenv/bash_env.sh" PATH="$_p9_buried" \
    NEXUS_ROOT="$SB9" NEXUS_SHIMWRAP_GLOB="$SB9/monitor/*wrap" \
    NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
    NEXUS_ASSERT_SKIP_NPROC=1 NEXUS_ASSERT_NO_ANCESTRY=1 NEXUS_CC_HOME="$CC11_FOREIGN" \
    bash "$ASSERT" 2>&1); SNAP_RC=$?
if [[ "$SNAP_RC" == "1" && "$SNAP_OUT" == *"REFUSING SPAWN: ambient"* && "$SNAP_OUT" == *"live probes already refused, so that refusal stands"* && "$SNAP_OUT" != *"READ AS FOREIGN"* ]]; then
    ok "#1477 (f) MEASURED: FOREIGN snapshot + this spawn's OWN env buried → the live legs refuse (rc 1); the foreign artifact is noted, not used to allow"
else
    bad "#1477 (f)" "expected rc 1 from the live legs with the snapshot leg deferring to them, got rc=$SNAP_RC: $SNAP_OUT"
fi

# (g) F1 — the w225 skeptic's finding, reproduced by the orchestrator at
# 8bd0d2b7: on the mtime route the leg adjudicated ONE file, so a newer FOREIGN
# snapshot MASKED an older BURIED nexus one (rc 0, "READ AS FOREIGN", the buried
# file never mentioned) — #652 re-opened by one hand-launched `claude`, on every
# headless spawn path. This host sat in that mixed state for 43 min on
# 2026-09-06. The leg must now walk the listing and adjudicate the newest
# NEXUS-PROVENANCE file; the foreign one is counted, never allowed to mask.
CC11_MIX="$SB/cc11-mix"; mkdir -p "$CC11_MIX/shell-snapshots"
cp "$CC11_BURIED/shell-snapshots/snapshot-zsh-1-test.sh" "$CC11_MIX/shell-snapshots/snapshot-zsh-0-buried.sh"
touch -d '2000-01-01 00:00:00' "$CC11_MIX/shell-snapshots/snapshot-zsh-0-buried.sh"
printf 'export PATH=%s\n' "$DEC9:/usr/bin:/bin" > "$CC11_MIX/shell-snapshots/snapshot-zsh-9-foreign.sh"   # newest, FOREIGN
_snap_live "$CC11_MIX"
if [[ "$SNAP_RC" == "1" && "$SNAP_OUT" == *"REFUSING SPAWN"* && "$SNAP_OUT" == *"1 newer FOREIGN file(s) passed over"* && "$SNAP_OUT" != *"READ AS FOREIGN"* ]]; then
    ok "#1477 F1: a FOREIGN snapshot newer than a BURIED nexus one does NOT mask it — the buried file is adjudicated (rc 1) and the route says one foreign file was passed over"
else
    bad "#1477 F1 masking" "expected rc 1 with the buried file adjudicated and the foreign one counted, got rc=$SNAP_RC: $SNAP_OUT"
fi

# (h) F2 — SHIM-SET DRIFT is not BURIAL. `_asw_snap_has_shimdir` was ONE bit per
# snapshot, so a name whose OWN shim dir is absent from the recorded PATH read
# as buried: add a monitor/*wrap and every worker spawn from an orchestrator
# started before the addition would refuse until it restarts (armed, not live).
# Per name now: own dir ABSENT -> drift, warn; PRESENT but behind -> burial.
mkdir -p "$SB9/monitor/newwrap"
printf '#!/bin/sh\necho WRAP\n' > "$SB9/monitor/newwrap/newtool"; chmod +x "$SB9/monitor/newwrap/newtool"
printf '#!/bin/sh\necho DECOY\n' > "$DEC9/newtool"; chmod +x "$DEC9/newtool"
CC11_DRIFT="$SB/cc11-drift"; _mk_snapshot "$CC11_DRIFT" "$SB9/monitor/ghwrap:$SB9/monitor/pipwrap:$DEC9:/usr/bin:/bin"          # newwrap ABSENT
CC11_NEWBUR="$SB/cc11-newbur"; _mk_snapshot "$CC11_NEWBUR" "$SB9/monitor/ghwrap:$SB9/monitor/pipwrap:$DEC9:$SB9/monitor/newwrap:/usr/bin:/bin"   # newwrap PRESENT, behind the decoy
_snap_live "$CC11_DRIFT" PATH="$SB9/monitor/newwrap:$_p9_wrapped"
if [[ "$SNAP_RC" == "0" && "$SNAP_OUT" == *"SHIM-SET DRIFT"* && "$SNAP_OUT" != *"REFUSING SPAWN"* ]]; then
    ok "#1477 F2: a snapshot that PREDATES a shim dir (newwrap absent, other shim dirs present) is DRIFT — warned, rc 0, never a burial refusal"
else
    bad "#1477 F2 drift" "expected a drift warning and rc 0, got rc=$SNAP_RC: $SNAP_OUT"
fi
_snap_live "$CC11_NEWBUR" PATH="$SB9/monitor/newwrap:$_p9_wrapped"
if [[ "$SNAP_RC" == "1" && "$SNAP_OUT" == *"REFUSING SPAWN"* && "$SNAP_OUT" != *"SHIM-SET DRIFT"* ]]; then
    ok "#1477 F2 CONTROL: the same name with its own shim dir PRESENT but BEHIND the decoy is still a BURIAL — refused (rc 1), so the drift arm did not weaken the guard"
else
    bad "#1477 F2 control" "expected the burial refusal to stand (rc 1), got rc=$SNAP_RC: $SNAP_OUT"
fi
rm -rf "$SB9/monitor/newwrap" "$DEC9/newtool"   # leave SB9 as the later cases expect it

# ---------------------------------------------------------------------------
# Case 12 — NON-HERMETIC: the REAL host's newest snapshot (your-org/nexus-code#1477).
#
# Every snapshot case above plants a synthetic snapshot into a synthetic CC
# home through the NEXUS_CC_HOME seam. That seam is what makes those cases
# honest — and it is ALSO what made the outage class unobservable: no hermetic
# case can notice that the newest snapshot on THIS host belongs to a session
# that was never nexus-launched. So this case drops the seam, lets the guard
# select the way a real spawn does (the mtime proxy — ancestry is disabled so
# the suite's OWN tool shell does not stand in for "the newest on the host"),
# and asserts the guard's behaviour against the host's actual state:
#
#   newest snapshot nexus-fronted   -> no snapshot objection (a refusal here is a
#                                      TRUE #652 finding about this host, and the
#                                      case is right to go red)
#   newest snapshot FOREIGN         -> the #1477 warning, rc 0, no refusal — the
#                                      live outage condition, handled
#   no snapshot on this host (CI)   -> SKIPPED, LOUDLY and COUNTED: the arm is
#                                      unmeasured here, not passed
#
# Independent discovery, so the case does not ask the guard to grade itself:
# the same two homes the guard consults, `ls -t`, and a provenance grep for a
# `monitor/*wrap` dir in the LAST `export PATH=` — the guard's own definition,
# re-derived rather than read back.
# ---------------------------------------------------------------------------
HOST_SNAP=""
for _cch in ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR"} "$HOME/.claude"; do
    [[ -d "$_cch/shell-snapshots" ]] || continue
    HOST_SNAP=$(bash -c 'ls -t "$1"/shell-snapshots/snapshot-*.sh 2>/dev/null | head -1' _ "$_cch")
    [[ -n "$HOST_SNAP" ]] && break
done
if [[ -z "$HOST_SNAP" || ! -r "$HOST_SNAP" ]]; then
    skip "non-hermetic #1477 (1/2): no Claude Code shell snapshot on this host — the real-host provenance arm is UNMEASURED here (CI has no CC home); not a pass"
    skip "non-hermetic #1477 (2/2): the guard's verdict on the host's newest snapshot is UNMEASURED for the same reason"
else
    HOST_PATH=$(sed -n 's/^[[:space:]]*export PATH=//p' "$HOST_SNAP" | tail -1 | sed 's/^"//; s/"$//')
    HOST_PROV=foreign
    grep -Eq '(^|:)[^:]*/monitor/[A-Za-z0-9_.-]*wrap(:|$)' <<<"$HOST_PATH" && HOST_PROV=nexus
    printf '  NOTE: real host newest snapshot: %s (mtime %s) — provenance by independent grep: %s\n' \
        "$HOST_SNAP" "$(stat -c %y "$HOST_SNAP" 2>/dev/null | cut -c1-16)" "$HOST_PROV"
    _repo_front="$REPO_ROOT/monitor/ghwrap:$REPO_ROOT/monitor/pipwrap:$REPO_ROOT/monitor/notifywrap:$REPO_ROOT/monitor/tmuxwrap"
    HOST_OUT=$(env -u NEXUS_CC_HOME -u NEXUS_ASSERT_SNAPSHOT -u NEXUS_SPAWNER_SNAPSHOT -u NEXUS_IS_ORCHESTRATOR \
        -u NEXUS_PREV_BASH_ENV -u NEXUS_INHERITED_PATH -u NEXUS_INHERITED_PATH_PID \
        -u NEXUS_INHERITED_PATH_UPSTREAM -u NEXUS_INHERITED_PATH_UPSTREAM_PID -u NEXUS_PATH_FRONT_OFF \
        PATH="$_repo_front:$PATH" NEXUS_ROOT="$REPO_ROOT" ZDOTDIR="$REPO_ROOT/monitor/shellenv" \
        NEXUS_ASSERT_GH_SHELL="$ZSH_BIN" SHELL="$ZSH_BIN" NEXUS_ASSERT_SKIP_NPROC=1 NEXUS_ASSERT_NO_ANCESTRY=1 \
        "$ASSERT" 2>&1); HOST_RC=$?
    if [[ "$HOST_OUT" == *"snapshot leg examined $HOST_SNAP "* ]]; then
        ok "non-hermetic #1477: unseamed, the guard selected the SAME file this case found independently (${HOST_SNAP##*/}) — the mtime route, as a real spawn uses it"
    else
        bad "non-hermetic selection" "the guard did not examine $HOST_SNAP; output: $HOST_OUT"
    fi
    case "$HOST_PROV" in
        nexus)
            if [[ "$HOST_OUT" != *"frozen tool-shell snapshot resolves"* && "$HOST_RC" != 1 ]]; then
                ok "non-hermetic #1477: this host's newest snapshot is nexus-fronted and the snapshot leg does not object (rc=$HOST_RC)"
            else
                bad "non-hermetic BURIAL" "the newest snapshot on THIS host is nexus-fronted but BURIED — a real #652 condition on this host (rc=$HOST_RC): $HOST_OUT"
            fi ;;
        foreign)
            if [[ "$HOST_RC" == "0" && "$HOST_OUT" == *"READ AS FOREIGN"* && "$HOST_OUT" != *"REFUSING SPAWN"* ]]; then
                ok "non-hermetic #1477: this host is in the LIVE outage condition (newest snapshot is foreign) and the guard WARNS instead of refusing — the fix, observed on the real surface"
            else
                bad "non-hermetic FOREIGN" "the newest snapshot on THIS host is foreign and the guard did not handle it as #1477 requires (rc=$HOST_RC): $HOST_OUT"
            fi ;;
    esac
fi

# ---------------------------------------------------------------------------
# Case 13 — the probe shells run DETACHED from the controlling tty, and a
# probe that will not die is KILLED rather than waited on
# (your-org/nexus-code#1497).
#
# Measured 2026-09-06/08 (zsh 5.4.2, bash 4.4.20, GNU timeout 8.28), inside a
# tmux pane shaped exactly like `_respawn.sh`'s launcher: `timeout 40 $SHELL
# -lic …` NEVER answered. An interactive shell started in a BACKGROUND process
# group of the pane's tty (which is where a bare `timeout` puts its child) is
# stopped by job control the moment it touches the terminal; at 40 s the
# SIGTERM is ignored by an initialised interactive shell, and a `timeout`
# without `-k` then waits forever. Two orchestrator boots hung there with
# `pane-state` reading `unknown reason=live-descendant`; on the other runs the
# same probe cost 43 s and came back EMPTY — a guard blind on the one surface
# it exists to check. The fix runs every probe under `setsid -w … </dev/null`
# with `timeout -k`, which is also the faithful model of the surface probed:
# Claude Code snapshots its shell from a subprocess that has NO tty.
#
# Three arms, every one COUNTED (ok / bad / skip):
#   13a. POSITIVE CONTROL — the pty fixture (`script`) really hands a child a
#        controlling tty. Without it the tty arm is SKIPPED loudly, not passed.
#   13b. Under that pty, the login+interactive probe shell observes NO
#        controlling tty. Unpatched, it observed one (and hung on a real shell).
#   13c. A probe shell that ignores SIGTERM and sleeps is KILLED within
#        NEXUS_ASSERT_PROBE_TIMEOUT + NEXUS_ASSERT_PROBE_KILL_GRACE seconds and
#        the surface is reported EMPTY — the guard returns, it does not hang.
#
# The probe shell is a FAKE (`$FB13/zsh`, so the guard treats `-lic` as
# enforceable): it records whether it has a controlling tty, then answers the
# SHIMMARK / GHVERMARK protocol so every other leg stays green and the verdict
# under test is about the probe mechanics alone.
# ---------------------------------------------------------------------------
R13="$SB/root13"; mkdir -p "$R13/monitor/ghwrap" "$R13/monitor/pipwrap"
printf '#!/bin/sh\necho WRAP\n' > "$R13/monitor/ghwrap/gh";   chmod +x "$R13/monitor/ghwrap/gh"
printf '#!/bin/sh\necho WRAP\n' > "$R13/monitor/pipwrap/pip"; chmod +x "$R13/monitor/pipwrap/pip"
FB13="$SB/fakebin13"; mkdir -p "$FB13"; OBS13="$SB/probe13.observed"
cat > "$FB13/zsh" <<'FAKE13'
#!/bin/bash
# Fake probe shell for case 13: record the tty situation, then answer the probe.
obs="${FAKE13_OBS:?}"
flags="$1"; cmd="${2:-}"
if ( exec 3</dev/tty ) 2>/dev/null; then ctty=yes; else ctty=no; fi
printf 'flags=%s ctty=%s\n' "$flags" "$ctty" >> "$obs"
interactive=0
case "$flags" in *i*) interactive=1 ;; esac
if [ -n "${FAKE13_HANG:-}" ] && [ "$interactive" = 1 ]; then
    trap '' TERM            # an initialised interactive shell ignores SIGTERM
    sleep "$FAKE13_HANG"
    exit 0
fi
case "$cmd" in
    *GHVERMARK*) printf 'GHVERMARK:gh version 2.90.0 (2026-01-01)\n' ;;
    *)  for n in $NEXUS_ASSERT_SHIM_NAMES; do
            case "$n" in
                gh)  printf 'SHIMMARK:%s:%s\n' "$n" "$FAKE13_SHIMS/ghwrap/gh" ;;
                pip) printf 'SHIMMARK:%s:%s\n' "$n" "$FAKE13_SHIMS/pipwrap/pip" ;;
                *)   printf 'SHIMMARK:%s:\n' "$n" ;;
            esac
        done ;;
esac
FAKE13
chmod +x "$FB13/zsh"
_c13_env=( FAKE13_OBS="$OBS13" FAKE13_SHIMS="$R13/monitor" NEXUS_ROOT="$R13"
           NEXUS_ASSERT_GH_SHELL="$FB13/zsh" SHELL="$FB13/zsh"
           NEXUS_ASSERT_SKIP_NPROC=1 NEXUS_ASSERT_SKIP_SNAPSHOT=1
           PATH="$R13/monitor/ghwrap:$R13/monitor/pipwrap:$PATH" )

SCRIPT_BIN=$(command -v script 2>/dev/null || true)
CTTY_CTRL=""
if [[ -n "$SCRIPT_BIN" ]]; then
    CTTY_CTRL=$(timeout 20 "$SCRIPT_BIN" -qec 'sh -c "if ( exec 3</dev/tty ) 2>/dev/null; then echo CTTY=yes; else echo CTTY=no; fi"' /dev/null 2>/dev/null \
                | tr -d '\r' | grep -o 'CTTY=[a-z]*' | sed -n 1p)
fi
if [[ "$CTTY_CTRL" == "CTTY=yes" ]]; then
    ok "case 13a (positive control): the pty fixture hands a child a controlling tty ($SCRIPT_BIN)"
    : > "$OBS13"
    out13=$(timeout 90 "$SCRIPT_BIN" -qec "env $(printf '%q ' "${_c13_env[@]}") $(printf '%q' "$ASSERT")" /dev/null 2>&1); rc13=$?
    lic13=$(grep -E '^flags=-lic ' "$OBS13" 2>/dev/null | sed -n 1p)
    if [[ "$lic13" == *"ctty=no"* ]]; then
        ok "case 13b: under a pty, the login+interactive probe shell ran with NO controlling tty (observed: $lic13; guard rc=$rc13)"
    else
        bad "case 13b" "expected the -lic probe to observe ctty=no; observed '${lic13:-<no -lic invocation recorded>}' (guard rc=$rc13; out: $(printf '%s' "$out13" | tr -d '\r' | tail -c 600))"
    fi
else
    skip "case 13a: no working \`script\` to build a pty fixture (bin: ${SCRIPT_BIN:-absent}; control said '${CTTY_CTRL:-nothing}') — the tty arm is UNMEASURED here; not a pass"
    skip "case 13b: unmeasured for the same reason"
fi

: > "$OBS13"
_t13=$(date +%s)
out13c=$(env "${_c13_env[@]}" FAKE13_HANG=30 NEXUS_ASSERT_PROBE_TIMEOUT=1 NEXUS_ASSERT_PROBE_KILL_GRACE=1 \
         timeout 25 "$ASSERT" 2>&1); rc13c=$?
_el13=$(( $(date +%s) - _t13 ))
# `rc13c == 0`, NOT merely `!= 124` (your-org/nexus-code#1498 review). The
# property that makes killing a wedged probe SAFE is not that the guard comes
# BACK — it is that it comes back ALLOWING. This file exits 1 (:1451) and 79
# (:1461) on its refusal paths, so a `!= 124` test passes on a REFUSAL: the
# arm written to cover the kill path would go green on the day an empty
# surface starts halting every spawn, which given #1477's history on this
# exact file is the failure that matters. Pinning the verdict is what binds
# `_asw_probe_exec`'s guaranteed return to the degrade-to-allow arms it
# depends on.
if (( rc13c == 0 && _el13 <= 12 )) && [[ "$out13c" == *"did not resolve at all (empty)"* ]]; then
    ok "case 13c: a probe shell that ignores SIGTERM is KILLED at timeout+grace (${_el13}s), the surface is reported EMPTY, and the guard returned ALLOWING (rc=$rc13c) instead of hanging the launcher"
else
    bad "case 13c" "expected the guard back within a few seconds, ALLOWING (rc 0), with the EMPTY warning; took ${_el13}s rc=$rc13c; out: $(printf '%s' "$out13c" | tail -c 600)"
fi

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
EXPECT=59   # +3: case 11 (g)/(h), the w225 skeptic's F1/F2 arms; +6: case 8, the #652/#654 ambient-surface control (arms A/B/C)
            # +3: case 13, the tty-detached KILLABLE probe — the pty positive
            #     control, the no-controlling-tty observation (or two loud,
            #     COUNTED skips without `script`), and the kill-at-timeout+grace arm
            # +4: case 10, the FROZEN-SNAPSHOT surface ported from #670
            # +7: case 9b, the #1383 one-hop-up channel (arms D/E/F)
            # +13: case 11, #1477 FOREIGN vs BURIAL, the self-heal path, the
            #      spawner-carried route, and the measured foreign+dirty arm
            # +2: case 12, the NON-HERMETIC real-host arm — measured, or
            #     SKIPPED loudly and COUNTED (a skip is in RAN below)
(( HAVE_ZSH ))            && EXPECT=$(( EXPECT + 11 ))  # cases 1-4, plus 4b's
                                                        # self-prefixing-alias
                                                        # pair + its negative
                                                        # control (#892 F1)
[[ -n "$CEIL_PRECHECK" ]] && EXPECT=$(( EXPECT + 3 ))   # case 7a/b/c only
RAN=$(( PASS + FAIL + SKIP ))
if (( RAN == EXPECT )); then
    ok "assertion count: $RAN executed, $EXPECT expected for this host"
else
    bad "assertion count" "$RAN assertions executed but $EXPECT were expected (HAVE_ZSH=$HAVE_ZSH CEIL=${CEIL_PRECHECK:-none}) — a case stopped running, or a helper exited 127 and was counted by nothing"
fi

echo
if [[ $FAIL -eq 0 ]]; then
    if (( SKIP > 0 )); then
        # Green, with named holes: the skipped arms are UNMEASURED here, and the
        # verdict line says so rather than letting "ALL TESTS PASSED" vouch for them.
        printf 'ALL TESTS PASSED (%d) — %d SKIPPED (unmeasured on this host; see SKIP lines above)\n' "$PASS" "$SKIP"
    else
        printf 'ALL TESTS PASSED (%d)\n' "$PASS"
    fi
    exit 0
else
    printf '%d PASSED, %d FAILED, %d SKIPPED\n' "$PASS" "$FAIL" "$SKIP" >&2; exit 1
fi
