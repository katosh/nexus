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
# ...and on every INTERACTIVE shell (the ~/.zshrc linuxbrew re-prepend that
# #578's snapshot-generating login+interactive shell hit).
printf 'export PATH="%s:$PATH"\n' "$DECOY" > "$FAKE_HOME/.zshrc"
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

# --- zsh INTERACTIVE spawn shell (your-org/nexus-code#578) -----------------
# The prior zsh cases exercise `zsh -c` (non-interactive; sources .zshenv only).
# The #578 defect lived one layer deeper: an INTERACTIVE zsh sources .zshrc,
# which re-sources ~/.zshrc (linuxbrew re-prepend) — and the .zshrc proxy did
# NOT re-front, so the bot-default gh wrapper got buried in exactly the shell
# Claude Code snapshots for its Bash tool. This case pins the re-front in the
# interactive/login proxies via front-path.zsh.
echo "=== zsh INTERACTIVE spawn shell (#578) ==="
if command -v zsh >/dev/null 2>&1; then
    # WITH the real proxies: interactive zsh sources ~/.zshrc (decoy prepend)
    # then front-path.zsh re-fronts — the wrapper + nexus tools must win.
    out=$(
        export NEXUS_ROOT="$REPO_ROOT" NEXUS_LOCALS="$FAKE_LOCALS"
        # shellcheck disable=SC1090,SC1091
        . "$REPO_ROOT/monitor/locals-env.sh"    # sets ZDOTDIR=real shellenv
        ZSH_COMPDUMP="$SB/.zcompdump" HOME="$FAKE_HOME" zsh -ic "$RESOLVE"
    )
    assert_resolution "zsh INTERACTIVE WITH re-front" "$out"

    # WITHOUT the re-front: a broken shellenv whose .zshrc re-sources ~/.zshrc
    # but omits front-path.zsh — the decoy MUST shadow (proves the fixture bites
    # and that the re-front is load-bearing, not incidental).
    BROKEN_ZDOTDIR="$SB/broken-shellenv"; mkdir -p "$BROKEN_ZDOTDIR"
    # .zshenv fronts the nexus (like the real one) so the ONLY difference under
    # test is the missing interactive re-front.
    cp "$REPO_ROOT/monitor/shellenv/.zshenv" "$BROKEN_ZDOTDIR/.zshenv"
    cp "$REPO_ROOT/monitor/shellenv/front-path.zsh" "$BROKEN_ZDOTDIR/front-path.zsh"
    printf '[ -r "$HOME/.zshrc" ] && . "$HOME/.zshrc"\n' > "$BROKEN_ZDOTDIR/.zshrc"
    out=$(
        export NEXUS_ROOT="$REPO_ROOT" NEXUS_LOCALS="$FAKE_LOCALS"
        # shellcheck disable=SC1090,SC1091
        . "$REPO_ROOT/monitor/locals-env.sh"
        export ZDOTDIR="$BROKEN_ZDOTDIR"        # override the real one
        ZSH_COMPDUMP="$SB/.zcompdump" HOME="$FAKE_HOME" zsh -ic "$RESOLVE"
    )
    assert_decoy_wins "zsh INTERACTIVE WITHOUT re-front" "$out"
else
    printf '  SKIP: zsh not installed — interactive zsh coverage skipped (CI installs zsh)\n'
fi

# ===========================================================================
# locals-env.sh must MOVE-TO-FRONT, not prepend-if-absent (#578 repair).
#
# WHY this is the load-bearing case. The Bash tool does NOT re-front per
# command: it runs `zsh -c "source <snapshot> && <cmd>"`, and the snapshot's
# final `export PATH=` line CLOBBERS whatever $ZDOTDIR/.zshenv just did. That
# frozen PATH is verbatim the PATH the `claude` process inherited from the
# spawn launcher — so the launcher's `. locals-env.sh` is the ONLY chance to
# get the order right. The old presence guard ("already in PATH → skip")
# tested presence and ignored POSITION, so when `tmux new-window` handed the
# worker's login zsh an env that already carried the wrapper dirs and
# ~/.zshrc then re-prepended linuxbrew on top, locals-env declined to repair
# the burial and the bad order was frozen into every snapshot.
# ===========================================================================
echo
echo "== locals-env.sh move-to-front =="

# Position (1-based) of an exact dir within a PATH string; empty if absent.
_pos() { printf '%s' "$2" | awk -F: -v d="$1" '{for(i=1;i<=NF;i++) if($i==d){print i; exit}}' | head -1; }
# Count of exact occurrences of a dir in a PATH string.
_count() { printf '%s' "$2" | awk -F: -v d="$1" '{c=0; for(i=1;i<=NF;i++) if($i==d) c++; print c}'; }

# HERMETIC: strip BASH_ENV/ZDOTDIR. Both point at the sibling re-front hooks
# (shellenv/bash_env.sh, shellenv/.zshenv), which ALREADY move-to-front
# correctly — leaving them set would front the dirs no matter what
# locals-env.sh did, and this block would pass against the very defect it
# exists to catch. This isolates locals-env.sh as the only actor.
_clean_env=(env -u NEXUS_LOCALS -u NEXUS_ROOT -u NEXUS_LOCALS_PATH_ONLY
            -u BASH_ENV -u NEXUS_PREV_BASH_ENV -u NEXUS_BASH_ENV_CHAINED -u ZDOTDIR)
_source_path() {   # $1=shell  $2=initial PATH
    "${_clean_env[@]}" NEXUS_ROOT="$REPO_ROOT" NEXUS_LOCALS="$FAKE_LOCALS" PATH="$2" \
        "$1" -c ". '$REPO_ROOT/monitor/locals-env.sh' >/dev/null 2>&1; printf '%s' \"\$PATH\""
}

GHW="$REPO_ROOT/monitor/ghwrap"
NTW="$REPO_ROOT/monitor/notifywrap"
PPW="$REPO_ROOT/monitor/pipwrap"
LBIN="$FAKE_LOCALS/bin"
# The exact shape of the live failure: every nexus dir present but BURIED
# behind a competing entry, as ~/.zshrc's linuxbrew re-prepend leaves it.
# /usr/bin:/bin keep the spawned shell's own rc (Lmod's modules.sh) quiet.
BURIED="$DECOY:$GHW:$NTW:$PPW:$LBIN:/usr/bin:/bin"

# TEETH: the fixture must genuinely start buried, or the test proves nothing.
if [[ "$(_pos "$GHW" "$BURIED")" == "1" ]]; then
    bad "fixture sanity" "BURIED PATH already has ghwrap at front — test has no teeth"
else
    ok "fixture sanity (ghwrap starts buried at position $(_pos "$GHW" "$BURIED"))"
fi

for sh_bin in /bin/bash "$(command -v zsh 2>/dev/null)"; do
    [[ -x "$sh_bin" ]] || continue
    sh_name=$(basename "$sh_bin")

    got=$(_source_path "$sh_bin" "$BURIED")
    # ghwrap leads, then notifywrap, pipwrap, locals/bin — the established
    # invariant, now reached from a buried start rather than an absent one.
    if [[ "$(_pos "$GHW" "$got")" == "1" && "$(_pos "$NTW" "$got")" == "2" \
       && "$(_pos "$PPW" "$got")" == "3" && "$(_pos "$LBIN" "$got")" == "4" ]]; then
        ok "$sh_name: buried nexus dirs moved to front in order"
    else
        bad "$sh_name: buried nexus dirs moved to front in order" "got: $got"
    fi

    # A buried dir must be MOVED, not copied — no duplicate left behind.
    n=$(_count "$GHW" "$got")
    [[ "$n" == "1" ]] && ok "$sh_name: no duplicate ghwrap entry" \
                      || bad "$sh_name: no duplicate ghwrap entry" "found $n copies"

    # Pre-existing duplicates collapse to the single front copy.
    got=$(_source_path "$sh_bin" "$DECOY:$GHW:/usr/bin:$GHW:/bin")
    n=$(_count "$GHW" "$got")
    [[ "$(_pos "$GHW" "$got")" == "1" && "$n" == "1" ]] \
        && ok "$sh_name: duplicate ghwrap copies collapse to one at front" \
        || bad "$sh_name: duplicate ghwrap copies collapse to one at front" "got: $got"

    # Empty PATH elements mean "cwd" — dropping them would silently change
    # resolution semantics for whoever set them. bash only: zsh normalises
    # PATH through its `path` array tie and discards empty elements itself,
    # before any nexus code runs, so there is nothing for us to preserve.
    if [[ "$sh_name" == "bash" ]]; then
        got=$(_source_path "$sh_bin" ":$DECOY::$GHW:/usr/bin:")
        n=$(printf '%s' "$got" | awk -F: '{c=0; for(i=1;i<=NF;i++) if($i=="") c++; print c}')
        [[ "$n" == "3" ]] && ok "$sh_name: empty PATH elements preserved" \
                          || bad "$sh_name: empty PATH elements preserved" "expected 3 empties, got $n in: $got"
    fi

    # Sourcing twice must be a no-op the second time.
    once=$(_source_path "$sh_bin" "$BURIED")
    twice=$("${_clean_env[@]}" NEXUS_ROOT="$REPO_ROOT" NEXUS_LOCALS="$FAKE_LOCALS" PATH="$BURIED" \
            "$sh_bin" -c ". '$REPO_ROOT/monitor/locals-env.sh' >/dev/null 2>&1; . '$REPO_ROOT/monitor/locals-env.sh' >/dev/null 2>&1; printf '%s' \"\$PATH\"")
    [[ "$once" == "$twice" ]] && ok "$sh_name: idempotent across re-source" \
                              || bad "$sh_name: idempotent across re-source" "once=$once twice=$twice"

    # The internal helper must not leak into the sourcing shell.
    leak=$("${_clean_env[@]}" NEXUS_ROOT="$REPO_ROOT" NEXUS_LOCALS="$FAKE_LOCALS" PATH="$BURIED" \
           "$sh_bin" -c ". '$REPO_ROOT/monitor/locals-env.sh' >/dev/null 2>&1; command -v _le_front_dir 2>/dev/null || echo NONE")
    [[ "$leak" == "NONE" ]] && ok "$sh_name: _le_front_dir does not leak into the shell" \
                            || bad "$sh_name: _le_front_dir does not leak into the shell" "found: $leak"

    # PATH-ONLY mode is the operator's OWN interactive shell. Its documented
    # contract is that homebrew shadowing nexus tools there is deliberately
    # fine — so a buried locals/bin must be left exactly where it is, and no
    # wrapper dir may be added.
    got=$("${_clean_env[@]}" NEXUS_LOCALS_PATH_ONLY=1 \
          NEXUS_ROOT="$REPO_ROOT" NEXUS_LOCALS="$FAKE_LOCALS" PATH="$DECOY:$LBIN:/usr/bin:/bin" \
          "$sh_bin" -c ". '$REPO_ROOT/monitor/locals-env.sh' >/dev/null 2>&1; printf '%s' \"\$PATH\"")
    # Assert RELATIVE order, not an absolute index: a global rc outside our
    # control (/etc/zshenv in the sandbox prepends /app/bin) shifts indices.
    # The contract is that locals/bin stays BEHIND the competing dir.
    p_l=$(_pos "$LBIN" "$got"); p_d=$(_pos "$DECOY" "$got")
    if [[ -n "$p_l" && -n "$p_d" && "$p_l" -gt "$p_d" && "$(_count "$GHW" "$got")" == "0" ]]; then
        ok "$sh_name: PATH-ONLY mode leaves a buried locals/bin untouched"
    else
        bad "$sh_name: PATH-ONLY mode leaves a buried locals/bin untouched" "got: $got"
    fi
done

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
