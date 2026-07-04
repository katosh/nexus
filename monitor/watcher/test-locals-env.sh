#!/usr/bin/env bash
# Tests for monitor/locals-env.sh — the checked-in sourcer that joins the
# NEXUS-WIDE project-local toolchain: prepends locals/bin to PATH (idempotent)
# and redirects UV_* state into the nexus locals/ tree. Sourced by the
# spawn-worker, watcher, and orchestrator launchers, and by bootstrap-venv.sh.
# Part of your-org/your-nexus#236 (B7) / #307.
#
# Run: bash monitor/watcher/test-locals-env.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Fully hermetic (no network).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
ENVSH="$_repo_root/monitor/locals-env.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$ENVSH" ]] || { echo "missing env file: $ENVSH" >&2; exit 1; }

# Every assertion subshell must be hermetic against the AMBIENT environment.
# Nexus-spawned agent shells — the exact context operators and workers run
# this suite from — carry locals-env full-mode exports: NEXUS_PREV_BASH_ENV
# (the stashed operator Lmod BASH_ENV), a redirected BASH_ENV/ZDOTDIR, UV_*
# state, and NEXUS_*; operator interactive shells can carry
# NEXUS_LOCALS_PATH_ONLY (the rc hook's assignment prefix on the `.` special
# builtin persists in POSIX-mode shells). Any of these leaking into a case
# subshell flips its assertions (your-org/nexus-code#405 G1: B3 failed under
# an agent shell because inherited NEXUS_PREV_BASH_ENV survived the PATH-only
# early return). Unset EVERY variable locals-env.sh reads or writes; each
# case re-exports only its own sentinels afterwards.
isolate_ambient_env() {
    unset NEXUS_ROOT NEXUS_LOCALS NEXUS_LOCALS_PATH_ONLY NEXUS_PREV_BASH_ENV \
          BASH_ENV ZDOTDIR UV_PYTHON_INSTALL_DIR UV_CACHE_DIR UV_TOOL_DIR
}

echo "=== self-location + env values ==="

# (1) self-locating: sourced with NEXUS_ROOT unset, from an unrelated cwd, it
#     resolves the nexus root from its own location (monitor/..).
out=$(
    cd /tmp || exit 99
    isolate_ambient_env
    PATH="/usr/bin:/bin"
    # shellcheck disable=SC1090
    . "$ENVSH"
    printf 'NEXUS_LOCALS=%s\n' "$NEXUS_LOCALS"
    printf 'PATH0=%s\n' "${PATH%%:*}"
    case ":$PATH:" in *":$NEXUS_LOCALS/bin:"*) printf 'PATHHAS_LOCALS=1\n' ;; *) printf 'PATHHAS_LOCALS=0\n' ;; esac
    printf 'UV_PYTHON_INSTALL_DIR=%s\n' "$UV_PYTHON_INSTALL_DIR"
    printf 'UV_CACHE_DIR=%s\n' "$UV_CACHE_DIR"
    printf 'UV_TOOL_DIR=%s\n' "$UV_TOOL_DIR"
)
if grep -qx "NEXUS_LOCALS=$_repo_root/locals" <<<"$out"; then
    ok "self-locates nexus root from monitor/.. -> <root>/locals"
else
    bad "self-location" "got: $(grep '^NEXUS_LOCALS=' <<<"$out")"
fi
# Full mode prepends BOTH locals/bin and the bot-default gh wrapper dir
# (monitor/ghwrap); the wrapper dir is FORCE-front (prepended last) so a bare
# `gh` resolves to the bot default. Assert ghwrap leads and locals/bin is on PATH.
if grep -qx "PATH0=$_repo_root/monitor/ghwrap" <<<"$out"; then
    ok "prepends the bot-default gh wrapper dir (monitor/ghwrap) to PATH front"
else
    bad "ghwrap PATH-front" "got: $(grep '^PATH0=' <<<"$out")"
fi
if grep -qx "PATHHAS_LOCALS=1" <<<"$out"; then
    ok "prepends locals/bin to PATH"
else
    bad "PATH prepend" "got: $(grep '^PATHHAS_LOCALS=' <<<"$out")"
fi
if grep -qx "UV_PYTHON_INSTALL_DIR=$_repo_root/locals/uv/python" <<<"$out" \
   && grep -qx "UV_CACHE_DIR=$_repo_root/locals/uv/cache" <<<"$out" \
   && grep -qx "UV_TOOL_DIR=$_repo_root/locals/uv/tools" <<<"$out"; then
    ok "redirects UV_PYTHON_INSTALL_DIR / UV_CACHE_DIR / UV_TOOL_DIR -> locals/uv/*"
else
    bad "UV_* redirect" "got: $(grep -E '^UV_' <<<"$out")"
fi

echo "=== honours pre-set NEXUS_ROOT and NEXUS_LOCALS ==="

# (2) a pre-set NEXUS_ROOT (exported by the spawn launcher) wins over
#     self-location.
out2=$(
    cd /tmp || exit 99
    isolate_ambient_env
    export NEXUS_ROOT="/tmp/some-nexus"
    PATH="/usr/bin:/bin"
    # shellcheck disable=SC1090
    . "$ENVSH"
    printf 'NEXUS_LOCALS=%s\n' "$NEXUS_LOCALS"
)
if grep -qx "NEXUS_LOCALS=/tmp/some-nexus/locals" <<<"$out2"; then
    ok "pre-set \$NEXUS_ROOT pins the toolchain"
else
    bad "NEXUS_ROOT honoured" "got: $(grep '^NEXUS_LOCALS=' <<<"$out2")"
fi

# (3) a pre-set NEXUS_LOCALS (bootstrap-venv passes a custom --locals) wins.
# NEXUS_ROOT is unset (isolate_ambient_env) so this is HERMETIC: locals-env
# self-locates its root to
# THIS checkout (which has monitor/ghwrap), exactly as CI does — not whatever
# NEXUS_ROOT the ambient shell exports. The override redirects the *locals*
# tree (UV state + locals/bin), but the bot-default gh wrapper dir
# (monitor/ghwrap) is still force-front in full mode, so it — not locals/bin —
# is PATH0. Assert the override by UV-state redirect + locals/bin PRESENCE on
# PATH, not by PATH0 (which is legitimately ghwrap now).
out3=$(
    cd /tmp || exit 99
    isolate_ambient_env
    export NEXUS_LOCALS="/tmp/custom-locals"
    PATH="/usr/bin:/bin"
    # shellcheck disable=SC1090
    . "$ENVSH"
    printf 'UV_CACHE_DIR=%s\n' "$UV_CACHE_DIR"
    case ":$PATH:" in *":/tmp/custom-locals/bin:"*) printf 'PATHHAS_CUSTOMBIN=1\n' ;; *) printf 'PATHHAS_CUSTOMBIN=0\n' ;; esac
)
if grep -qx "UV_CACHE_DIR=/tmp/custom-locals/uv/cache" <<<"$out3" \
   && grep -qx "PATHHAS_CUSTOMBIN=1" <<<"$out3"; then
    ok "pre-set \$NEXUS_LOCALS overrides the locals tree"
else
    bad "NEXUS_LOCALS honoured" "got: $(grep -E '^(UV_CACHE_DIR|PATHHAS_CUSTOMBIN)=' <<<"$out3")"
fi

echo "=== PATH-only mode (NEXUS_LOCALS_PATH_ONLY) ==="

# (P) The manual-window rc hook sources with NEXUS_LOCALS_PATH_ONLY=1: it
#     must still prepend locals/bin (so claude/ng resolve by name) but must
#     NOT redirect the user's uv state into the nexus tree.
outp=$(
    cd /tmp || exit 99
    isolate_ambient_env
    export NEXUS_LOCALS_PATH_ONLY=1
    PATH="/usr/bin:/bin"
    # shellcheck disable=SC1090
    . "$ENVSH"
    printf 'PATH0=%s\n' "${PATH%%:*}"
    printf 'UV_CACHE_DIR=%s\n' "${UV_CACHE_DIR:-<unset>}"
    printf 'UV_PYTHON_INSTALL_DIR=%s\n' "${UV_PYTHON_INSTALL_DIR:-<unset>}"
    printf 'UV_TOOL_DIR=%s\n' "${UV_TOOL_DIR:-<unset>}"
    printf 'NEXUS_LOCALS=%s\n' "$NEXUS_LOCALS"
)
if grep -qx "PATH0=$_repo_root/locals/bin" <<<"$outp"; then
    ok "PATH-only: still prepends locals/bin"
else
    bad "PATH-only PATH" "got: $(grep '^PATH0=' <<<"$outp")"
fi
if grep -qx 'UV_CACHE_DIR=<unset>' <<<"$outp" \
   && grep -qx 'UV_PYTHON_INSTALL_DIR=<unset>' <<<"$outp" \
   && grep -qx 'UV_TOOL_DIR=<unset>' <<<"$outp"; then
    ok "PATH-only: leaves UV_* unset (no global uv-state hijack)"
else
    bad "PATH-only UV_*" "uv state was set: $(grep -E '^UV_' <<<"$outp")"
fi
if grep -qx "NEXUS_LOCALS=$_repo_root/locals" <<<"$outp"; then
    ok "PATH-only: still exports NEXUS_LOCALS"
else
    bad "PATH-only NEXUS_LOCALS" "got: $(grep '^NEXUS_LOCALS=' <<<"$outp")"
fi

echo "=== BASH_ENV chaining (bash spawn re-front hook) ==="

# (B1) full mode points BASH_ENV at shellenv/bash_env.sh and STASHES the
#      operator's prior BASH_ENV (Lmod init etc.) into NEXUS_PREV_BASH_ENV, so
#      bash_env.sh can chain to it instead of clobbering it.
outb=$(
    cd /tmp || exit 99
    isolate_ambient_env
    export BASH_ENV="/sentinel/prior-bash-env"
    PATH="/usr/bin:/bin"
    # shellcheck disable=SC1090
    . "$ENVSH"
    printf 'BASH_ENV=%s\n' "$BASH_ENV"
    printf 'PREV=%s\n' "${NEXUS_PREV_BASH_ENV:-<unset>}"
)
if grep -qx "BASH_ENV=$_repo_root/monitor/shellenv/bash_env.sh" <<<"$outb" \
   && grep -qx 'PREV=/sentinel/prior-bash-env' <<<"$outb"; then
    ok "full mode points BASH_ENV at bash_env.sh and stashes the prior value"
else
    bad "BASH_ENV redirect" "got: $(grep -E '^(BASH_ENV|PREV)=' <<<"$outb")"
fi

# (B2) idempotent: a re-source must NOT overwrite NEXUS_PREV_BASH_ENV with our
#      OWN bash_env.sh path (which would make bash_env.sh source itself).
outb2=$(
    cd /tmp || exit 99
    isolate_ambient_env
    export BASH_ENV="/sentinel/prior-bash-env"
    PATH="/usr/bin:/bin"
    # shellcheck disable=SC1090
    . "$ENVSH"; . "$ENVSH"; . "$ENVSH"
    printf 'PREV=%s\n' "${NEXUS_PREV_BASH_ENV:-<unset>}"
)
if grep -qx 'PREV=/sentinel/prior-bash-env' <<<"$outb2"; then
    ok "idempotent: triple-source keeps NEXUS_PREV_BASH_ENV at the real prior value"
else
    bad "BASH_ENV idempotency" "got: $(grep '^PREV=' <<<"$outb2")"
fi

# (B3) PATH-only mode (operator's interactive shell) must NOT touch BASH_ENV —
#      it returns before the redirect, so the user's bare shell is unaffected.
outb3=$(
    cd /tmp || exit 99
    isolate_ambient_env
    export NEXUS_LOCALS_PATH_ONLY=1
    export BASH_ENV="/sentinel/prior-bash-env"
    PATH="/usr/bin:/bin"
    # shellcheck disable=SC1090
    . "$ENVSH"
    printf 'BASH_ENV=%s\n' "$BASH_ENV"
    printf 'PREV=%s\n' "${NEXUS_PREV_BASH_ENV:-<unset>}"
)
if grep -qx 'BASH_ENV=/sentinel/prior-bash-env' <<<"$outb3" \
   && grep -qx 'PREV=<unset>' <<<"$outb3"; then
    ok "PATH-only: leaves BASH_ENV untouched (operator's interactive shell unaffected)"
else
    bad "PATH-only BASH_ENV" "got: $(grep -E '^(BASH_ENV|PREV)=' <<<"$outb3")"
fi

echo "=== idempotency + purity ==="

# (4) double-source must not duplicate the PATH entry.
out4=$(
    cd /tmp || exit 99
    isolate_ambient_env
    PATH="/usr/bin:/bin"
    # shellcheck disable=SC1090
    . "$ENVSH"; . "$ENVSH"; . "$ENVSH"
    printf '%s\n' "$PATH" | tr ':' '\n' | grep -c "/locals/bin$"
)
if [[ "$out4" == "1" ]]; then
    ok "idempotent: triple-source yields exactly one locals/bin PATH entry"
else
    bad "PATH idempotency" "locals/bin appears $out4 times (want 1)"
fi

# (5) pure: sourcing creates NO directories / files (no side effects).
out5=$(
    sb=$(mktemp -d)
    cd "$sb" || exit 99
    isolate_ambient_env
    export NEXUS_LOCALS="$sb/locals"
    PATH="/usr/bin:/bin"
    # shellcheck disable=SC1090
    . "$ENVSH"
    n=$(find "$sb" -mindepth 1 2>/dev/null | wc -l)
    printf 'CREATED=%s\n' "$n"
    rm -rf "$sb"
)
if grep -qx 'CREATED=0' <<<"$out5"; then
    ok "pure: sourcing creates no dirs/files (provisioning is bootstrap-venv's job)"
else
    bad "purity" "sourcing created $(grep '^CREATED=' <<<"$out5") entries"
fi

# (6) preserves the existing PATH tail (doesn't clobber).
out6=$(
    cd /tmp || exit 99
    isolate_ambient_env
    PATH="/sentinel/path:/usr/bin"
    # shellcheck disable=SC1090
    . "$ENVSH"
    case ":$PATH:" in *":/sentinel/path:"*) echo KEPT ;; *) echo LOST ;; esac
)
if grep -qx 'KEPT' <<<"$out6"; then
    ok "preserves the existing PATH (prepend, not replace)"
else
    bad "PATH preservation" "existing PATH entry was lost"
fi

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
