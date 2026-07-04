#!/usr/bin/env bash
# Tests for the agent-spawn PATH force-front mechanism — the GENERALIZATION of
# your-org/nexus-code PR #349 (gh-only) to the WHOLE nexus toolchain, for BOTH
# bash and zsh spawn shells (PR #349 comment 4799289032).
#
# What it guards: in a freshly spawned agent shell, EVERY entry under
# locals/bin (uv, python, ng, claude, …) AND the bot-default gh wrapper must
# resolve to the NEXUS copy, even after a shell rc re-prepends a competing
# (linuxbrew/Lmod/system) directory on every invocation. The two hooks under
# test:
#   zsh  — $ZDOTDIR/.zshenv      (sourced on every zsh invocation)
#   bash — $BASH_ENV/bash_env.sh (sourced on every non-interactive bash -c)
# both set by monitor/locals-env.sh (full mode).
#
# TEETH: each shell is exercised twice — once WITH the nexus re-front hook
# (must resolve to nexus) and once WITHOUT it (negative control: the decoy MUST
# win). A no-op mechanism therefore cannot pass: the positive case would fail.
#
# Fully hermetic — no network, no real linuxbrew/Lmod. A fake "locals/bin" of
# decoy-named tools and a fake competing dir are built in a tmpdir; the rc
# re-prepend is simulated by a fake ~/.zshenv / prior-$BASH_ENV.
#
# Run: bash monitor/watcher/test-spawn-pathfront.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. zsh portion auto-SKIPs (still
# exit 0) if zsh is absent; CI installs zsh so it runs there.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$REPO_ROOT/monitor/locals-env.sh" ]]            || { echo "missing locals-env.sh" >&2; exit 1; }
[[ -f "$REPO_ROOT/monitor/shellenv/.zshenv" ]]         || { echo "missing shellenv/.zshenv" >&2; exit 1; }
[[ -f "$REPO_ROOT/monitor/shellenv/bash_env.sh" ]]     || { echo "missing shellenv/bash_env.sh" >&2; exit 1; }
[[ -x "$REPO_ROOT/monitor/ghwrap/gh" ]]                || { echo "missing ghwrap/gh" >&2; exit 1; }

# --- hermetic fixture ------------------------------------------------------
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

FAKE_LOCALS="$SB/locals"          # stands in for $NEXUS_ROOT/locals
DECOY="$SB/decoy"                 # stands in for linuxbrew/system
FAKE_HOME="$SB/home"              # for the simulated ~/.zshenv re-prepend
mkdir -p "$FAKE_LOCALS/bin" "$DECOY" "$FAKE_HOME"

# Tools to exercise: the operator's named examples + an arbitrary extra, plus a
# decoy `gh` to prove the ghwrap dir out-ranks even a same-named locals entry.
TOOLS="uv python ng claude mytool"
for t in $TOOLS; do
    printf '#!/bin/sh\necho NEXUS:%s\n' "$t" > "$FAKE_LOCALS/bin/$t"
    chmod +x "$FAKE_LOCALS/bin/$t"
    printf '#!/bin/sh\necho DECOY:%s\n' "$t" > "$DECOY/$t"
    chmod +x "$DECOY/$t"
done
# A decoy gh in the competing dir — ghwrap must still win.
printf '#!/bin/sh\necho DECOY:gh\n' > "$DECOY/gh"; chmod +x "$DECOY/gh"

# Simulated rc that re-prepends the decoy dir on every shell invocation.
printf 'export PATH="%s:$PATH"\n' "$DECOY" > "$FAKE_HOME/.zshenv"
PRIOR_BASH_ENV="$SB/prior-bash-env.sh"
printf 'export PATH="%s:$PATH"\n' "$DECOY" > "$PRIOR_BASH_ENV"

GHWRAP="$REPO_ROOT/monitor/ghwrap"

# Build the resolve payload run inside the spawned shell: print each tool's
# resolved path. (Single-quoted heredoc-free string; $TOOLS expanded by us.)
RESOLVE="for t in $TOOLS gh; do printf '%s|%s\\n' \"\$t\" \"\$(command -v \"\$t\" 2>/dev/null || echo NONE)\"; done"

# assert_resolution <label> <output> — every $TOOLS entry must be NEXUS
# (FAKE_LOCALS/bin), and gh must be the ghwrap copy.
assert_resolution() {
    local label="$1" out="$2" t line got miss=0
    for t in $TOOLS; do
        line=$(grep "^$t|" <<<"$out")
        got="${line#*|}"
        if [[ "$got" != "$FAKE_LOCALS/bin/$t" ]]; then
            bad "$label: $t" "resolved to '$got' (want $FAKE_LOCALS/bin/$t)"; miss=1
        fi
    done
    line=$(grep '^gh|' <<<"$out"); got="${line#*|}"
    if [[ "$got" != "$GHWRAP/gh" ]]; then
        bad "$label: gh" "resolved to '$got' (want $GHWRAP/gh — ghwrap must out-rank decoy)"; miss=1
    fi
    [[ $miss -eq 0 ]] && ok "$label: all $(wc -w <<<"$TOOLS") locals/bin entries + gh resolve to the nexus copy"
}

# assert_decoy_wins <label> <output> — negative control: with NO nexus re-front
# hook, the decoy MUST shadow the nexus tools (proves the fixture has teeth).
assert_decoy_wins() {
    local label="$1" out="$2" line got
    line=$(grep '^uv|' <<<"$out"); got="${line#*|}"
    if [[ "$got" == "$DECOY/uv" ]]; then
        ok "$label: decoy shadows nexus without the re-front hook (fixture has teeth)"
    else
        bad "$label" "expected decoy to win without hook, got uv -> '$got'"
    fi
}

# --- bash: WITH the nexus re-front (positive) ------------------------------
echo "=== bash spawn shell ==="
out=$(
    export NEXUS_ROOT="$REPO_ROOT" NEXUS_LOCALS="$FAKE_LOCALS"
    export BASH_ENV="$PRIOR_BASH_ENV"           # operator's prior BASH_ENV (Lmod-like)
    # shellcheck disable=SC1090,SC1091
    . "$REPO_ROOT/monitor/locals-env.sh"        # chains prior -> sets BASH_ENV=bash_env.sh
    bash -c "$RESOLVE"
)
assert_resolution "bash WITH re-front" "$out"

# --- bash: WITHOUT the nexus re-front (negative control) -------------------
out=$(
    export NEXUS_ROOT="$REPO_ROOT" NEXUS_LOCALS="$FAKE_LOCALS"
    # Start with nexus fronted (as the launcher would), then let ONLY the prior
    # BASH_ENV (decoy re-prepend) run — no bash_env.sh re-front.
    PATH="$FAKE_LOCALS/bin:$GHWRAP:$PATH"
    export BASH_ENV="$PRIOR_BASH_ENV"
    bash -c "$RESOLVE"
)
assert_decoy_wins "bash WITHOUT re-front" "$out"

# --- zsh: WITH and WITHOUT (positive + negative control) -------------------
echo "=== zsh spawn shell ==="
if command -v zsh >/dev/null 2>&1; then
    out=$(
        export NEXUS_ROOT="$REPO_ROOT" NEXUS_LOCALS="$FAKE_LOCALS"
        # shellcheck disable=SC1090,SC1091
        . "$REPO_ROOT/monitor/locals-env.sh"    # sets ZDOTDIR=shellenv (+ BASH_ENV, harmless here)
        HOME="$FAKE_HOME" zsh -c "$RESOLVE"      # ZDOTDIR/.zshenv sources fake ~/.zshenv then re-fronts
    )
    assert_resolution "zsh WITH re-front" "$out"

    out=$(
        export NEXUS_ROOT="$REPO_ROOT" NEXUS_LOCALS="$FAKE_LOCALS"
        # shellcheck disable=SC1090,SC1091
        . "$REPO_ROOT/monitor/locals-env.sh"
        unset ZDOTDIR                            # negative control: no nexus .zshenv re-front
        PATH="$FAKE_LOCALS/bin:$GHWRAP:$PATH"    # nexus fronted at launch...
        HOME="$FAKE_HOME" zsh -c "$RESOLVE"      # ...then fake ~/.zshenv buries it, nothing re-fronts
    )
    assert_decoy_wins "zsh WITHOUT re-front" "$out"
else
    printf '  SKIP: zsh not installed — zsh spawn-shell coverage skipped (CI installs zsh)\n'
fi

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
