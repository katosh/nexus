#!/usr/bin/env bash
# Tests for monitor/gh-shim.sh — the shared `gh` bot-default classification +
# token logic (consumed by the PATH-front wrapper monitor/ghwrap/gh; see
# test-gh-wrapper.sh for the delivery-mechanism tests). Anchors on the PR #345
# / comment 4790310194 repro: a bare `gh pr comment` must resolve to the BOT,
# not the operator. The zsh-integration section also proves the PATH-front
# delivery (wrapper resolves first, even after a late linuxbrew re-prepend).
#
# Run: bash monitor/watcher/test-gh-shim.sh
# Expected: ALL TESTS PASSED, exit 0. Hermetic — no network, no real gh,
# no real token mint (both are stubbed).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SHIM="$_repo_root/monitor/gh-shim.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[ -f "$SHIM" ] || { echo "missing shim: $SHIM" >&2; exit 1; }

# --- Hermetic harness ----------------------------------------------------
# A fake `gh` binary first on PATH. `command gh` (what the shim calls)
# resolves to it. It prints the GH_TOKEN it was invoked with + its argv so
# assertions can read which identity would have been used.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'FGH'
#!/usr/bin/env bash
printf 'FAKEGH token=[%s] argv=[%s]\n' "${GH_TOKEN:-}" "$*"
FGH
chmod +x "$FAKEBIN/gh"

# Stub mint-token.sh via the MINT_TOKEN_BIN override (the same env knob the
# watcher uses). Prints a recognisable bot token.
BOT_TOKEN="ghs_BOTTOKEN_minted"
MINT_OK="$WORK/mint-ok.sh"
cat > "$MINT_OK" <<MINT
#!/usr/bin/env bash
printf '%s\n' "$BOT_TOKEN"
MINT
chmod +x "$MINT_OK"
MINT_EMPTY="$WORK/mint-empty.sh"
cat > "$MINT_EMPTY" <<'MINT'
#!/usr/bin/env bash
printf '%s' ''
MINT
chmod +x "$MINT_EMPTY"
MINT_FAIL="$WORK/mint-fail.sh"
cat > "$MINT_FAIL" <<'MINT'
#!/usr/bin/env bash
exit 3
MINT
chmod +x "$MINT_FAIL"

export NEXUS_ROOT="$WORK/nexus"
mkdir -p "$NEXUS_ROOT/monitor/.state"
export PATH="$FAKEBIN:$PATH"

# Run a gh invocation in a clean subshell with the shim sourced. Each case
# controls its own env (GH_TOKEN, GH_IMPERSONATE*, WATCHER_WINDOW, MINT_*).
# Echoes: "<rc>|<stdout>".
run_shim() {
    (
        unset -f gh 2>/dev/null || true
        # shellcheck disable=SC1090
        . "$SHIM"
        out=$("$@" 2>/dev/null); rc=$?
        printf '%s|%s' "$rc" "$out"
    )
}
# Same, but capturing stderr instead of stdout.
run_shim_err() {
    (
        unset -f gh 2>/dev/null || true
        # shellcheck disable=SC1090
        . "$SHIM"
        err=$("$@" 2>&1 1>/dev/null); rc=$?
        printf '%s|%s' "$rc" "$err"
    )
}

echo "=== RED baseline (no shim): bare gh runs as operator ==="
# Without the function, `gh` is the fake binary directly, GH_TOKEN unset.
red=$( unset GH_TOKEN; gh pr comment 345 --body "On it" )
case "$red" in
    *'token=[]'*) ok "RED: bare gh (no shim) carries NO bot token (operator identity — the slip)" ;;
    *) bad "RED baseline" "expected empty token, got: $red" ;;
esac

echo "=== GREEN: writes default to the BOT ==="
# Canonical repro: bare `gh pr comment` → bot token injected.
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh pr comment 345 --body "On it" )
case "$r" in
    *"token=[$BOT_TOKEN]"*) ok "pr comment → bot token (repro fixed)" ;;
    *) bad "pr comment → bot" "got: $r" ;;
esac

r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh issue create --title x --body y )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "issue create → bot" ;; *) bad "issue create → bot" "got: $r" ;; esac

r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh pr create --head b --base dev --title t --body-file f )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "pr create → bot" ;; *) bad "pr create → bot" "got: $r" ;; esac

r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh release upload v1 a.tgz )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "release upload → bot" ;; *) bad "release upload → bot" "got: $r" ;; esac

echo "=== GREEN: api method/graphql/field classification ==="
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh api graphql -f query=mutation )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "api graphql → bot (default mutations to bot)" ;; *) bad "api graphql → bot" "got: $r" ;; esac

r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh api -X POST repos/o/r/issues/1/comments )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "api -X POST → bot" ;; *) bad "api -X POST → bot" "got: $r" ;; esac

r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh api --method=DELETE repos/o/r/issues/comments/9 )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "api --method=DELETE → bot" ;; *) bad "api --method=DELETE → bot" "got: $r" ;; esac

r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh api repos/o/r/issues/1/comments -F body=@note.md )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "api with -F field (defaults POST) → bot" ;; *) bad "api -F field → bot" "got: $r" ;; esac

# --input <file> is an implicit POST (skeptic finding on #349) → must be WRITE.
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh api repos/o/r/issues/1/comments --input body.json )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "api --input <file> (implicit POST) → bot" ;; *) bad "api --input → bot" "got: $r" ;; esac
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh api --input=body.json repos/o/r/x )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "api --input=<file> → bot" ;; *) bad "api --input= → bot" "got: $r" ;; esac
# --input - reads the body from stdin (still an implicit POST) → WRITE.
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh api repos/o/r/x --input - )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "api --input - (stdin body) → bot" ;; *) bad "api --input - → bot" "got: $r" ;; esac
# Explicit GET overrides the implicit-POST inference → passthrough.
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh api repos/o/r/x --input body.json -X GET )
case "$r" in *'token=[]'*) ok "api --input + explicit -X GET → passthrough (read)" ;; *) bad "api --input -X GET" "got: $r" ;; esac

echo "=== PASS-THROUGH: reads + gh auth carry NO injected token ==="
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh api /rate_limit )
case "$r" in *'token=[]'*) ok "api GET → passthrough (no token)" ;; *) bad "api GET passthrough" "got: $r" ;; esac

r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh pr view 1 )
case "$r" in *'token=[]'*) ok "pr view → passthrough" ;; *) bad "pr view passthrough" "got: $r" ;; esac

r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh issue list )
case "$r" in *'token=[]'*) ok "issue list → passthrough" ;; *) bad "issue list passthrough" "got: $r" ;; esac

r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh auth token )
case "$r" in *'token=[]'*) ok "gh auth token → passthrough (user-PAT path preserved)" ;; *) bad "gh auth passthrough" "got: $r" ;; esac

r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh api graphql -f query=query_only_read )
# graphql is intentionally classified WRITE → bot, even for a query. Assert that.
case "$r" in *"token=[$BOT_TOKEN]"*) ok "api graphql query → bot (conservative graphql rule)" ;; *) bad "api graphql query" "got: $r" ;; esac

echo "=== GH_TOKEN already set → passthrough unchanged (no double-inject) ==="
r=$( unset WATCHER_WINDOW; GH_TOKEN="preset_explicit" MINT_TOKEN_BIN="$MINT_OK" run_shim gh pr comment 1 --body x )
case "$r" in
    *"token=[preset_explicit]"*) ok "preset GH_TOKEN preserved (not overridden by mint)" ;;
    *) bad "preset GH_TOKEN passthrough" "got: $r" ;;
esac

echo "=== watcher safety: WATCHER_WINDOW set → passthrough even for a write ==="
r=$( unset GH_TOKEN; WATCHER_WINDOW=headless MINT_TOKEN_BIN="$MINT_OK" run_shim gh api graphql -f query=x )
case "$r" in *'token=[]'*) ok "WATCHER_WINDOW → write passes through untouched" ;; *) bad "watcher passthrough" "got: $r" ;; esac

echo "=== GH_IMPERSONATE escape hatch ==="
# Without a reason → refuse (rc 3), no gh call.
r=$( unset GH_TOKEN WATCHER_WINDOW GH_IMPERSONATE_REASON; GH_IMPERSONATE=1 MINT_TOKEN_BIN="$MINT_OK" run_shim gh pr comment 1 --body x )
rc="${r%%|*}"; body="${r#*|}"
if [ "$rc" = "3" ] && [ -z "${body//[[:space:]]/}" ]; then
    ok "GH_IMPERSONATE without reason → refuses (rc 3), no gh call"
else
    bad "impersonate no-reason" "rc=$rc body=[$body]"
fi

# With a reason → operator identity (no injected token), logs an audit line.
r=$( unset GH_TOKEN WATCHER_WINDOW; GH_IMPERSONATE=1 GH_IMPERSONATE_REASON="external repo, no bot install" MINT_TOKEN_BIN="$MINT_OK" run_shim gh pr comment 1 --body x )
case "$r" in
    *'token=[]'*) ok "GH_IMPERSONATE with reason → operator identity (no bot token)" ;;
    *) bad "impersonate with reason" "got: $r" ;;
esac
if [ -s "$NEXUS_ROOT/monitor/.state/impersonate.log" ] && grep -q "external repo, no bot install" "$NEXUS_ROOT/monitor/.state/impersonate.log"; then
    ok "GH_IMPERSONATE → audit line written to impersonate.log"
else
    bad "impersonate audit" "no audit line in impersonate.log"
fi

# --dangerously-impersonate pseudo-flag → stripped before gh, operator identity.
r=$( unset GH_TOKEN WATCHER_WINDOW GH_IMPERSONATE; GH_IMPERSONATE_REASON="r" MINT_TOKEN_BIN="$MINT_OK" run_shim gh --dangerously-impersonate pr comment 1 --body x )
case "$r" in
    *'--dangerously-impersonate'*) bad "pseudo-flag strip" "flag leaked to gh: $r" ;;
    *'token=[]'*) ok "--dangerously-impersonate → operator identity, flag stripped from argv" ;;
    *) bad "pseudo-flag" "got: $r" ;;
esac

echo "=== fail-loud: empty / failed mint refuses the WRITE ==="
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_EMPTY" run_shim gh pr comment 1 --body x )
rc="${r%%|*}"; body="${r#*|}"
if [ "$rc" != "0" ] && [ -z "${body//[[:space:]]/}" ]; then
    ok "empty mint → refuses WRITE (rc=$rc), no gh call (no operator fallthrough)"
else
    bad "empty mint refuse" "rc=$rc body=[$body]"
fi
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_FAIL" run_shim gh issue comment 1 --body x )
rc="${r%%|*}"; body="${r#*|}"
if [ "$rc" != "0" ] && [ -z "${body//[[:space:]]/}" ]; then
    ok "failed mint → refuses WRITE (rc=$rc), no gh call"
else
    bad "failed mint refuse" "rc=$rc body=[$body]"
fi

echo "=== leading --repo VALUE before the group is not mis-parsed ==="
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh -R your-org/nexus-code pr comment 345 --body x )
case "$r" in *"token=[$BOT_TOKEN]"*) ok "gh -R owner/repo pr comment → still classified WRITE → bot" ;; *) bad "leading -R parse" "got: $r" ;; esac

echo "=== FAIL-CLOSED classification (your-org/nexus-code#568 A3) ==="
# Table-driven identity assertions. Before the inversion the classifier
# defaulted to READ, so any group with no `case` arm — and any subcommand an
# arm did not enumerate — routed through the OPERATOR's ambient credentials.
# The five surfaces below are the ones an independent probe confirmed doing
# exactly that, plus the two structural cases (an unrecognised group; a
# recognised group's unenumerated subcommand) that let the gap re-open.
#
# Row format: <expect bot|op> <argv…>. `bot` = the minted token was injected;
# `op` = passthrough with no token (operator identity).
expect_identity() {
    local want="$1"; shift
    local label="$*"
    local r; r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim gh "$@" )
    case "$want:$r" in
        "bot:"*"token=[$BOT_TOKEN]"*) ok "gh $label → BOT" ;;
        "op:"*'token=[]'*)            ok "gh $label → operator passthrough" ;;
        bot:*) bad "gh $label" "expected BOT token, got: $r" ;;
        op:*)  bad "gh $label" "expected operator passthrough, got: $r" ;;
    esac
}

# The five empirically-confirmed operator-routing writes.
expect_identity bot project item-create --owner o --title t
expect_identity bot project item-add 1 --owner o --url u
expect_identity bot project item-delete 1 --owner o --id x
expect_identity bot project item-edit --id x --field-id f --text t
expect_identity bot project close 1 --owner o
expect_identity bot project field-delete --id f
expect_identity bot codespace create -r o/r
expect_identity bot codespace delete -c name
expect_identity bot release delete-asset v1 asset.tgz
expect_identity bot repo deploy-key add key.pub
expect_identity bot agent-task create --body x

# Structural case 1: a command GROUP the shim has never heard of. This is the
# one that keeps the gap closed as gh grows new surface.
expect_identity bot totally-new-group create --thing x
expect_identity bot --repo o/r totally-new-group create   # global flag value skipped

# Structural case 2: a recognised group, subcommand absent from its read
# allowlist. `pr update-branch` and `issue unpin` exist in gh and were never
# enumerated by the old write lists.
expect_identity bot pr update-branch 1
expect_identity bot issue unpin 1
expect_identity bot repo autolink create --key-prefix K --url U

# The reads these groups DO declare must still reach the operator — the
# inversion must not sweep the read surface into the bot.
expect_identity op  project list --owner o
expect_identity op  project item-list 1 --owner o
expect_identity op  codespace list
expect_identity op  release download v1
expect_identity op  repo deploy-key list
expect_identity op  agent-task list
expect_identity op  org list
expect_identity op  ruleset list
expect_identity op  attestation verify a.tgz -o o
expect_identity op  run watch 123
expect_identity op  cache list
expect_identity op  secret list
expect_identity op  workflow view w.yml
expect_identity op  search issues --repo o/r
expect_identity op  status
expect_identity op  browse --no-browser

# Bare / flags-only invocations are reads, not unrecognised groups.
expect_identity op  --version
expect_identity op  --help

# `gh <group>` with no subcommand prints help → read, never a mint.
expect_identity op  pr
expect_identity op  project

# The fail-closed verdict announces itself on stderr rather than surprising
# the caller with an unexplained bot identity (suppressible: GH_SHIM_QUIET).
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim_err gh totally-new-group create )
case "$r" in
    *'fail-closed'*) ok "unclassified WRITE announces the fail-closed verdict on stderr" ;;
    *) bad "fail-closed announcement" "got: $r" ;;
esac
r=$( unset GH_TOKEN WATCHER_WINDOW; GH_SHIM_QUIET=1 MINT_TOKEN_BIN="$MINT_OK" run_shim_err gh totally-new-group create )
if [ -z "${r#0|}" ]; then
    ok "GH_SHIM_QUIET=1 suppresses the announcement"
else
    bad "GH_SHIM_QUIET" "expected empty stderr, got: $r"
fi
# An explicitly-classified write stays quiet — the note is for the default arm.
r=$( unset GH_TOKEN WATCHER_WINDOW; MINT_TOKEN_BIN="$MINT_OK" run_shim_err gh pr comment 1 --body x )
if [ -z "${r#0|}" ]; then
    ok "an allowlist-classified WRITE (pr comment) prints no note"
else
    bad "note scope" "expected empty stderr for pr comment, got: $r"
fi

echo "=== token scoping: the injected GH_TOKEN must not persist (#568) ==="
# `VAR=… func` is only call-scoped under zsh/bash; POSIX shells persist it.
# The shim uses an explicit subshell so the scoping does not depend on which
# shell sourced it. Assert the variable is gone in the caller after a write.
r=$(
    unset -f gh 2>/dev/null || true
    unset GH_TOKEN WATCHER_WINDOW
    # shellcheck disable=SC1090
    . "$SHIM"
    MINT_TOKEN_BIN="$MINT_OK" gh pr comment 1 --body x >/dev/null 2>&1
    printf 'after=[%s]' "${GH_TOKEN:-}"
)
case "$r" in
    'after=[]') ok "GH_TOKEN does not leak into the caller after a WRITE" ;;
    *) bad "GH_TOKEN scoping" "got: $r" ;;
esac
# Same assertion under a POSIX-conformant shell, where the old prefix-assignment
# form genuinely persisted. dash is the reference; skip cleanly if absent.
if command -v dash >/dev/null 2>&1; then
    r=$( PATH="$FAKEBIN:$PATH" NEXUS_ROOT="$NEXUS_ROOT" MINT_TOKEN_BIN="$MINT_OK" \
         dash -c ". '$SHIM'; unset GH_TOKEN; gh pr comment 1 --body x >/dev/null 2>&1; printf 'after=[%s]' \"\${GH_TOKEN:-}\"" 2>/dev/null )
    case "$r" in
        'after=[]') ok "dash: GH_TOKEN does not leak after a WRITE (POSIX prefix-assignment trap closed)" ;;
        *) bad "dash GH_TOKEN scoping" "got: $r" ;;
    esac
else
    echo "  (skip: dash not available — POSIX persistence case unexercised)"
fi

echo "=== zsh integration: real ZDOTDIR/.zshenv delivery path ==="
# The production mechanism is the PATH-FRONT wrapper (monitor/ghwrap/gh):
# ZDOTDIR=$NEXUS_ROOT/monitor/shellenv → .zshenv FORCE-prepends the wrapper dir
# to PATH (after ~/.zshenv), so every `zsh -c` an agent runs resolves `gh` to
# the wrapper. These assertions are hermetic (no network): they prove the
# wrapper RESOLVES FIRST in a real zsh (incl. after a late re-prepend) and
# EXECUTES via no-gh-call branches (impersonate refusal + fail-loud mint).
if command -v zsh >/dev/null 2>&1; then
    SHELLENV="$_repo_root/monitor/shellenv"
    GHWRAP="$_repo_root/monitor/ghwrap"
    # (a) ZDOTDIR set by full-mode locals-env; NOT set by PATH-ONLY mode.
    z=$( unset ZDOTDIR; NEXUS_ROOT="$_repo_root" . "$_repo_root/monitor/locals-env.sh" >/dev/null 2>&1; printf '%s' "${ZDOTDIR:-}" )
    [ "$z" = "$SHELLENV" ] && ok "locals-env (full) exports ZDOTDIR=$SHELLENV" || bad "ZDOTDIR full mode" "got [$z]"
    z=$( unset ZDOTDIR; NEXUS_ROOT="$_repo_root" NEXUS_LOCALS_PATH_ONLY=1 . "$_repo_root/monitor/locals-env.sh" >/dev/null 2>&1; printf '%s' "${ZDOTDIR:-<unset>}" )
    [ "$z" = "<unset>" ] && ok "locals-env PATH-ONLY does NOT set ZDOTDIR (operator interactive safe)" || bad "ZDOTDIR path-only" "got [$z]"

    # (b) `gh` resolves to the WRAPPER in a zsh that loaded our ZDOTDIR —
    #     top-level and nested. `command -v gh` returns the resolved path.
    t=$( NEXUS_ROOT="$_repo_root" ZDOTDIR="$SHELLENV" zsh -c 'command -v gh' 2>/dev/null )
    [ "$t" = "$GHWRAP/gh" ] && ok "zsh -c: gh resolves to the PATH-front wrapper" || bad "zsh gh wrapper resolution" "command -v: $t (expected $GHWRAP/gh)"
    t=$( NEXUS_ROOT="$_repo_root" ZDOTDIR="$SHELLENV" zsh -c 'zsh -c "command -v gh"' 2>/dev/null )
    [ "$t" = "$GHWRAP/gh" ] && ok "nested zsh -c: wrapper still resolves first (ZDOTDIR exported)" || bad "nested zsh gh wrapper" "command -v: $t (expected $GHWRAP/gh)"

    # (b2) RACE-WIN: simulate ~/.zshenv re-prepending a linuxbrew-like dir that
    #      ALSO holds a `gh` (the real one) AFTER our launch-time prepend. The
    #      per-command .zshenv force-front must still make the WRAPPER win.
    LATEDIR="$WORK/latebrew"; mkdir -p "$LATEDIR"; cp "$FAKEBIN/gh" "$LATEDIR/gh"; chmod +x "$LATEDIR/gh"
    t=$( NEXUS_ROOT="$_repo_root" ZDOTDIR="$SHELLENV" \
         zsh -c "path=('$LATEDIR' \$path); source '$SHELLENV/.zshenv'; command -v gh" 2>/dev/null )
    [ "$t" = "$GHWRAP/gh" ] && ok "race-win: wrapper resolves AHEAD of a late linuxbrew-like gh re-prepend" || bad "race-win" "command -v: $t (expected $GHWRAP/gh)"

    # (c) write + empty mint → refuse (rc 1), no gh call, no network.
    out=$( NEXUS_ROOT="$_repo_root" ZDOTDIR="$SHELLENV" GH_TOKEN= MINT_TOKEN_BIN="$MINT_EMPTY" \
           zsh -c 'gh pr comment 1 --body x >/dev/null 2>/tmp/ghsz.$$; echo "rc=$?"'; rm -f /tmp/ghsz.$$ 2>/dev/null )
    case "$out" in *"rc=1"*) ok "zsh -c: write + empty mint → refuses (rc 1), no network" ;; *) bad "zsh fail-loud" "got: $out" ;; esac

    # (d) GH_IMPERSONATE without reason → refuse (rc 3) in real zsh.
    out=$( NEXUS_ROOT="$_repo_root" ZDOTDIR="$SHELLENV" GH_TOKEN= GH_IMPERSONATE=1 GH_IMPERSONATE_REASON= \
           zsh -c 'gh pr comment 1 --body x 2>/dev/null; echo "rc=$?"' )
    case "$out" in *"rc=3"*) ok "zsh -c: GH_IMPERSONATE w/o reason → refuses (rc 3)" ;; *) bad "zsh impersonate refuse" "got: $out" ;; esac
else
    echo "  (skip: zsh not available)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "ALL TESTS PASSED"; exit 0; else echo "TESTS FAILED" >&2; exit 1; fi
