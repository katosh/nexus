#!/usr/bin/env bash
# Tests for monitor/bootstrap-install.sh's "ensure a claude binary"
# sequence — install-then-resolve, the fresh-operator fix.
#
# THE INVARIANT under test: a fresh operator with NO claude binary
# anywhere (no $CLAUDE_BIN override, no project-local install, no
# system claude on PATH) must be able to run the bootstrap. Before
# this sequence existed, _claude-bin.sh's fail-loud exit killed the
# bootstrap before the agent that was supposed to perform the install
# ever launched (chicken-and-egg, reproduced by operator cfinkbei).
#
# Pinned behavior:
#   - no binary anywhere → bootstrap runs install-claude-local.sh,
#     then execs the freshly installed project-local binary;
#   - project-local binary already present → install skipped;
#   - operator-set $CLAUDE_BIN → install skipped, override honored;
#   - system claude on PATH → install skipped, system binary used;
#   - install failure → bootstrap exits non-zero with the recovery
#     text, and does NOT fall through to the resolver's confusing
#     "no claude binary found";
#   - pre-flight refusal (existing config/nexus.yml) fires BEFORE any
#     install attempt;
#   - the composed prompt tells the agent which binary it runs on.
#
# Fully hermetic: tmux, claude, and install-claude-local.sh are stubs,
# and PATH is reduced to a symlink farm of coreutils so no real
# claude / node / npm can leak in from the host.
#
# Run: bash monitor/watcher/test-bootstrap-claude-install.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
BOOTSTRAP_SRC="$_repo_root/monitor/bootstrap-install.sh"
RESOLVER_SRC="$_repo_root/monitor/_claude-bin.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$BOOTSTRAP_SRC" ]] || { echo "missing: $BOOTSTRAP_SRC" >&2; exit 1; }
[[ -f "$RESOLVER_SRC" ]]  || { echo "missing: $RESOLVER_SRC" >&2; exit 1; }

# readlink -f: the bootstrap canonicalizes its own path, so fixture
# paths must be canonical too or the exec'd-binary-path assertions
# would miss on hosts where $TMPDIR contains a symlink.
WORK=$(readlink -f "$(mktemp -d)")
trap 'rm -rf "$WORK"' EXIT

# --- hermetic PATH: coreutils symlink farm ---------------------------------
# The fresh-operator case requires that NO real `claude` (nor node/npm)
# is reachable. Every bootstrap run gets PATH = per-fixture stub dir
# (tmux stub, optional fake system claude) + this farm of symlinks to
# the coreutils the scripts under test actually invoke.
TOOL_FARM="$WORK/toolfarm"
mkdir -p "$TOOL_FARM"
for tool in bash sh cat sed awk grep mktemp rm mkdir cp mv ln chmod \
            dirname basename readlink env date tee touch ls; do
    p=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$p" "$TOOL_FARM/$tool"
done

# ---------------------------------------------------------------------------
# Fixture: a fake nexus tree holding the REAL bootstrap-install.sh and
# _claude-bin.sh, a STUB install-claude-local.sh (records each call,
# then installs a fake binary or fails per $INSTALL_STUB_MODE), the
# clone-shape markers the self-checks demand, and a stub bin dir
# holding tmux. Sets $NEXUS / $STUB_BIN / $INSTALL_LOG / $PROMPT_DUMP.
# ---------------------------------------------------------------------------
new_fixture() {
    NEXUS="$WORK/nexus.$RANDOM$RANDOM"
    STUB_BIN="$NEXUS/.stubbin"
    INSTALL_LOG="$NEXUS/.install-invocations.log"
    PROMPT_DUMP="$NEXUS/.prompt-dump"
    mkdir -p "$NEXUS/monitor" "$NEXUS/config" "$STUB_BIN"

    cp "$BOOTSTRAP_SRC" "$NEXUS/monitor/bootstrap-install.sh"
    cp "$RESOLVER_SRC"  "$NEXUS/monitor/_claude-bin.sh"
    chmod +x "$NEXUS/monitor/bootstrap-install.sh"

    # Clone-shape markers the self-checks look for.
    : > "$NEXUS/monitor/ng";              chmod +x "$NEXUS/monitor/ng"
    : > "$NEXUS/config/nexus.example.yml"
    : > "$NEXUS/watcher";                 chmod +x "$NEXUS/watcher"
    printf '# fake install prompt body\n' > "$NEXUS/monitor/install-prompt.md"

    # Template for every fake claude binary: prints a marker with its
    # own path + first arg, dumps the prompt (arg 2) for inspection.
    cat > "$NEXUS/.fake-claude-template" <<EOF
#!/usr/bin/env bash
echo "FAKE_CLAUDE_RAN marker=\$FAKE_CLAUDE_MARKER bin=\$0 flag=\${1:-}"
printf '%s' "\${2:-}" > "$PROMPT_DUMP"
exit 0
EOF

    # Stub installer: append to the invocation log, then install the
    # fake project-local binary (success) or fail loud (fail).
    cat > "$NEXUS/monitor/install-claude-local.sh" <<EOF
#!/usr/bin/env bash
echo "invoked" >> "$INSTALL_LOG"
case "\${INSTALL_STUB_MODE:-success}" in
    success)
        mkdir -p "$NEXUS/node_modules/.bin"
        cp "$NEXUS/.fake-claude-template" "$NEXUS/node_modules/.bin/claude"
        chmod +x "$NEXUS/node_modules/.bin/claude"
        echo "install-claude-local: 9.9.9 (stub install)"
        exit 0 ;;
    fail)
        echo "install-claude-local: npm install failed; rerun manually: cd $NEXUS && npm install" >&2
        exit 1 ;;
    *)
        echo "stub: unknown INSTALL_STUB_MODE" >&2
        exit 99 ;;
esac
EOF
    chmod +x "$NEXUS/monitor/install-claude-local.sh"

    # tmux stub (bootstrap calls `tmux rename-window`).
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/tmux"
    chmod +x "$STUB_BIN/tmux"
}

# Place a fake claude binary at an arbitrary path.
make_fake_claude() {  # $1 = destination path, $2 = marker string
    mkdir -p "$(dirname "$1")"
    cp "$NEXUS/.fake-claude-template" "$1"
    chmod +x "$1"
    # Bake the marker in so the run output identifies WHICH binary ran.
    sed -i "s|\$FAKE_CLAUDE_MARKER|$2|" "$1"
}

# Run the bootstrap inside the fixture under the hermetic PATH and the
# fake tmux/sandbox env the self-checks demand. Extra VAR=val args pass
# through to env (e.g. INSTALL_STUB_MODE, CLAUDE_BIN).
run_bootstrap() {
    env -i \
        HOME="$NEXUS" \
        USER="testop" \
        PATH="$STUB_BIN:$TOOL_FARM" \
        TMUX="/tmp/fake-tmux-socket,1234,0" \
        SANDBOX_ACTIVE=1 \
        SANDBOX_PROJECT_DIR="$NEXUS" \
        "$@" \
        bash "$NEXUS/monitor/bootstrap-install.sh"
}

install_invocations() {
    [[ -f "$INSTALL_LOG" ]] && grep -c 'invoked' "$INSTALL_LOG" || echo 0
}

echo "=== fresh operator: no claude anywhere ==="

# (1) No $CLAUDE_BIN, no project-local binary, no system claude →
# bootstrap runs the installer, then execs the fresh project-local
# binary with --dangerously-skip-permissions.
new_fixture
out=$(run_bootstrap INSTALL_STUB_MODE=success FAKE_CLAUDE_MARKER=local 2>&1)
rc=$?
if (( rc == 0 )) \
    && [[ "$(install_invocations)" == "1" ]] \
    && grep -q "FAKE_CLAUDE_RAN marker=local bin=$NEXUS/node_modules/.bin/claude flag=--dangerously-skip-permissions" <<<"$out"; then
    ok "fresh operator → installer runs, project-local binary exec'd"
else
    bad "fresh operator install-then-resolve" \
        "rc=$rc installs=$(install_invocations) out=$out"
fi

# (2) The old failure mode must be gone: no resolver "no claude binary
# found" anywhere in the output.
if ! grep -q '_claude-bin.sh: no claude binary found' <<<"$out"; then
    ok "fresh operator → resolver fail-loud exit never reached"
else
    bad "resolver error leaked" "out=$out"
fi

# (3) The composed prompt tells the agent which binary it runs on and
# that the bootstrap already performed the install.
prompt=$(cat "$PROMPT_DUMP" 2>/dev/null)
if grep -q "Claude binary:.*$NEXUS/node_modules/.bin/claude" <<<"$prompt" \
    && grep -q 'installed by this bootstrap' <<<"$prompt"; then
    ok "prompt context names the fresh-installed binary"
else
    bad "prompt context" "prompt header: $(head -c 600 <<<"$prompt")"
fi

# (4) Idempotency: a second run in the same fixture (binary now
# present) must NOT reinvoke the installer, and still launches.
out=$(run_bootstrap INSTALL_STUB_MODE=success FAKE_CLAUDE_MARKER=local 2>&1)
rc=$?
if (( rc == 0 )) && [[ "$(install_invocations)" == "1" ]] \
    && grep -q 'FAKE_CLAUDE_RAN' <<<"$out"; then
    ok "second run → install skipped (still 1 invocation), binary exec'd"
else
    bad "idempotent second run" \
        "rc=$rc installs=$(install_invocations) out=$out"
fi

echo
echo "=== operator overrides skip the install ==="

# (5) Pre-existing project-local binary → installer never invoked.
new_fixture
make_fake_claude "$NEXUS/node_modules/.bin/claude" preexisting-local
out=$(run_bootstrap 2>&1)
rc=$?
if (( rc == 0 )) && [[ "$(install_invocations)" == "0" ]] \
    && grep -q 'FAKE_CLAUDE_RAN marker=preexisting-local' <<<"$out"; then
    ok "pre-existing project-local binary → no install, local binary used"
else
    bad "pre-existing local binary" \
        "rc=$rc installs=$(install_invocations) out=$out"
fi

# (6) Operator-set $CLAUDE_BIN → installer never invoked, override wins
# even over a present system claude.
new_fixture
make_fake_claude "$NEXUS/override/claude" override
make_fake_claude "$STUB_BIN/claude" system
out=$(run_bootstrap CLAUDE_BIN="$NEXUS/override/claude" 2>&1)
rc=$?
if (( rc == 0 )) && [[ "$(install_invocations)" == "0" ]] \
    && grep -q 'FAKE_CLAUDE_RAN marker=override' <<<"$out"; then
    ok "\$CLAUDE_BIN override → no install, override binary used"
else
    bad "CLAUDE_BIN override" \
        "rc=$rc installs=$(install_invocations) out=$out"
fi

# (7) System claude on PATH (no local install) → installer never
# invoked, system binary used. Operators intentionally on system
# claude are not forced into a local install.
new_fixture
make_fake_claude "$STUB_BIN/claude" system
out=$(run_bootstrap 2>&1)
rc=$?
if (( rc == 0 )) && [[ "$(install_invocations)" == "0" ]] \
    && grep -q 'FAKE_CLAUDE_RAN marker=system' <<<"$out"; then
    ok "system claude on PATH → no install, system binary used"
else
    bad "system claude honored" \
        "rc=$rc installs=$(install_invocations) out=$out"
fi

echo
echo "=== install failure is fail-loud and actionable ==="

# (8) Installer fails → bootstrap exits non-zero, surfaces the
# installer's own error plus the relaunch recovery, and never reaches
# the resolver's "no claude binary found".
new_fixture
out=$(run_bootstrap INSTALL_STUB_MODE=fail 2>&1)
rc=$?
if (( rc != 0 )) \
    && grep -q 'npm install failed' <<<"$out" \
    && grep -q 'install failed' <<<"$out" \
    && grep -q 'relaunch the bootstrap' <<<"$out" \
    && ! grep -q '_claude-bin.sh: no claude binary found' <<<"$out"; then
    ok "install failure → non-zero exit, actionable error, no resolver noise"
else
    bad "install failure handling" "rc=$rc out=$out"
fi

# (9) A failed install must not leave a claude process exec'd.
if ! grep -q 'FAKE_CLAUDE_RAN' <<<"$out"; then
    ok "install failure → claude never launched"
else
    bad "claude launched despite failed install" "out=$out"
fi

echo
echo "=== ordering: pre-flight refusal fires before any install ==="

# (10) Existing config/nexus.yml (no --force) → exit 3 BEFORE the
# install block; the installer must never run.
new_fixture
: > "$NEXUS/config/nexus.yml"
out=$(run_bootstrap INSTALL_STUB_MODE=success 2>&1)
rc=$?
if (( rc == 3 )) && [[ "$(install_invocations)" == "0" ]] \
    && grep -q 'already exists' <<<"$out"; then
    ok "existing config refusal → exit 3, installer never invoked"
else
    bad "pre-flight ordering" \
        "rc=$rc installs=$(install_invocations) out=$out"
fi

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    echo "FAIL"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
