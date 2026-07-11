#!/usr/bin/env bash
# Tests for monitor/ghwrap/gh — the PATH-FRONT bot-default `gh` wrapper.
#
# These prove the DELIVERY mechanism (the executable wrapper), complementing
# test-gh-shim.sh (which proves the shared classification logic). The headline
# claims under test, per the operator request (your-org/nexus-code PR #349
# comment 4795415597):
#   1. The wrapper resolves the REAL gh excluding ITSELF — no recursion even
#      when the wrapper dir is FIRST on PATH.
#   2. A bare `gh` WRITE through the wrapper injects the bot token; a READ
#      passes through.
#   3. The wrapper is inherited by NON-zsh children (bash subshell, `python
#      subprocess`) — the gap the old zsh-function shim left.
#   4. WATCHER_WINDOW / preset-GH_TOKEN / GH_IMPERSONATE semantics hold (the
#      wrapper sources gh-shim.sh, so the policy is single-sourced).
#
# Run: bash monitor/watcher/test-gh-wrapper.sh
# Expected: ALL TESTS PASSED, exit 0. Hermetic — no network, no real gh, no
# real token mint (a fake real-gh + stubbed mint-token.sh).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
WRAP="$_repo_root/monitor/ghwrap/gh"

# th_hermetic_path only (fork-bomb precondition guard, #479); the
# ok/bad helpers below are this test's own assertion style.
. "$_test_dir/_test_helpers.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[ -x "$WRAP" ] || { echo "missing/!exec wrapper: $WRAP" >&2; exit 1; }

# --- Hermetic harness ----------------------------------------------------
# A fake REAL gh in its OWN dir (NOT the wrapper dir). It echoes the GH_TOKEN
# it was invoked with + argv, and a marker proving the wrapper reached it.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REALDIR="$WORK/realbin"; mkdir -p "$REALDIR"
cat > "$REALDIR/gh" <<'FGH'
#!/usr/bin/env bash
printf 'REALGH token=[%s] argv=[%s]\n' "${GH_TOKEN:-}" "$*"
FGH
chmod +x "$REALDIR/gh"

BOT_TOKEN="ghs_BOTTOKEN_minted"
MINT_OK="$WORK/mint-ok.sh"
cat > "$MINT_OK" <<MINT
#!/usr/bin/env bash
printf '%s\n' "$BOT_TOKEN"
MINT
chmod +x "$MINT_OK"

export NEXUS_ROOT="$WORK/nexus"
mkdir -p "$NEXUS_ROOT/monitor/.state"
# The wrapper must locate gh-shim.sh; point NEXUS_ROOT's monitor at the real one.
ln -s "$_repo_root/monitor/gh-shim.sh" "$NEXUS_ROOT/monitor/gh-shim.sh"

WRAPDIR="$_repo_root/monitor/ghwrap"
# Production-shaped PATH: wrapper dir FIRST, then the real-gh dir. This is the
# recursion trap — a naive `command gh` from inside the wrapper would loop.
# th_hermetic_path keeps command_not_found.py resolvable (fork-bomb
# precondition, #479 / #457); the appended dir holds only that one
# symlink, so gh resolution order is untouched.
BASEPATH=$(th_hermetic_path "$WRAPDIR:$REALDIR:/usr/bin:/bin" "$WORK")

run() { # run <env-assignment...> ; uses GHA[] for gh args; echoes "<rc>|<stdout>"
    (
        out=$(env "PATH=$BASEPATH" "$@" "$WRAP" "${GHA[@]}" 2>/dev/null); rc=$?
        printf '%s|%s' "$rc" "$out"
    )
}

echo "=== recursion-safety + bot-default WRITE ==="
GHA=(pr comment 345 --body "On it")
r=$( run GH_TOKEN= MINT_TOKEN_BIN="$MINT_OK" )
case "$r" in
    *"REALGH token=[$BOT_TOKEN]"*) ok "wrapper (first on PATH) resolves the REAL gh, no recursion; WRITE → bot token" ;;
    *) bad "wrapper write → bot" "got: $r" ;;
esac

echo "=== READ passes through (no token) ==="
GHA=(pr view 1)
r=$( run GH_TOKEN= MINT_TOKEN_BIN="$MINT_OK" )
case "$r" in *"REALGH token=[]"*) ok "wrapper READ → passthrough (no injected token)" ;; *) bad "wrapper read passthrough" "got: $r" ;; esac

echo "=== preset GH_TOKEN preserved (no double-inject) ==="
GHA=(pr comment 1 --body x)
r=$( run GH_TOKEN=preset_explicit MINT_TOKEN_BIN="$MINT_OK" )
case "$r" in *"REALGH token=[preset_explicit]"*) ok "wrapper preserves a preset GH_TOKEN" ;; *) bad "wrapper preset token" "got: $r" ;; esac

echo "=== WATCHER_WINDOW → passthrough even for a write ==="
GHA=(api graphql -f query=x)
r=$( run GH_TOKEN= WATCHER_WINDOW=headless MINT_TOKEN_BIN="$MINT_OK" )
case "$r" in *"REALGH token=[]"*) ok "wrapper honours WATCHER_WINDOW → real gh untouched" ;; *) bad "wrapper watcher safety" "got: $r" ;; esac

echo "=== GH_IMPERSONATE escape hatch via the wrapper ==="
GHA=(pr comment 1 --body x)
r=$( run GH_TOKEN= GH_IMPERSONATE=1 GH_IMPERSONATE_REASON="ext repo, operator OK" MINT_TOKEN_BIN="$MINT_OK" )
case "$r" in *"REALGH token=[]"*) ok "wrapper GH_IMPERSONATE+reason → operator identity (no bot token)" ;; *) bad "wrapper impersonate" "got: $r" ;; esac
GHA=(pr comment 1 --body x)
r=$( run GH_TOKEN= GH_IMPERSONATE=1 GH_IMPERSONATE_REASON= MINT_TOKEN_BIN="$MINT_OK" )
rc="${r%%|*}"
[ "$rc" = "3" ] && ok "wrapper GH_IMPERSONATE w/o reason → refuses (rc 3)" || bad "wrapper impersonate no-reason" "rc=$rc body=[${r#*|}]"

echo "=== fail-loud: empty mint refuses the WRITE ==="
MINT_EMPTY="$WORK/mint-empty.sh"; printf '#!/usr/bin/env bash\nprintf %%s ""\n' > "$MINT_EMPTY"; chmod +x "$MINT_EMPTY"
GHA=(issue comment 1 --body x)
r=$( run GH_TOKEN= MINT_TOKEN_BIN="$MINT_EMPTY" )
rc="${r%%|*}"; body="${r#*|}"
{ [ "$rc" != "0" ] && [ -z "${body//[[:space:]]/}" ]; } && ok "wrapper empty mint → refuses (rc=$rc), no real-gh call" || bad "wrapper fail-loud" "rc=$rc body=[$body]"

echo "=== NON-zsh child coverage (the wrapper's headline advantage) ==="
# A bash subshell — NOT zsh, so the old function shim would NOT have been in
# scope. With the wrapper dir on PATH front, a bare `gh` inside bash resolves
# to the wrapper → bot token. This is what an agent's `bash -c`, a Makefile,
# or any non-zsh subprocess sees.
r=$( PATH="$BASEPATH" GH_TOKEN= MINT_TOKEN_BIN="$MINT_OK" NEXUS_ROOT="$NEXUS_ROOT" \
     bash -c 'gh pr comment 9 --body "from bash"' 2>/dev/null )
case "$r" in *"REALGH token=[$BOT_TOKEN]"*) ok "bash -c 'gh …' (non-zsh child) → wrapper → bot token" ;; *) bad "bash child coverage" "got: $r" ;; esac

# A python subprocess that shells out to `gh` — inherits the wrapper on PATH.
if command -v python3 >/dev/null 2>&1; then
    r=$( PATH="$BASEPATH" GH_TOKEN= MINT_TOKEN_BIN="$MINT_OK" NEXUS_ROOT="$NEXUS_ROOT" \
         python3 -c 'import subprocess; print(subprocess.run(["gh","issue","comment","3","--body","x"],stdout=subprocess.PIPE).stdout.decode(), end="")' 2>/dev/null )
    case "$r" in *"REALGH token=[$BOT_TOKEN]"*) ok "python subprocess gh → wrapper → bot token" ;; *) bad "python child coverage" "got: $r" ;; esac
else
    echo "  (skip: python3 not available)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "ALL TESTS PASSED"; exit 0; else echo "TESTS FAILED" >&2; exit 1; fi
