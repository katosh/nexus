#!/usr/bin/env bash
# Tests for monitor/bootstrap-venv.sh — the NEXUS-WIDE, self-contained
# project-local Python toolchain with ZERO home-dir and ZERO Lmod dependency.
# Addresses B7 of your-org/your-nexus#236 + #307 (standalone checksum-pinned
# uv shared at the nexus root, all UV_* state redirected, per-project venvs
# under locals/venvs/, PATH via monitor/locals-env.sh).
#
# Run: bash monitor/watcher/test-bootstrap-venv.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# The default suite is HERMETIC: it asserts the nexus-wide env mutations, the
# planned (standalone, checksum-pinned) uv invocation, the static
# no-lmod/no-home properties, and a SIMULATED fresh-tmpfs interpreter-survival
# — all with no network and no download. An OPT-IN live end-to-end proof (real
# download + checksum + interpreter provision + $HOME wipe + shared-toolchain
# reuse) runs only when BV_LIVE_TEST=1 (needs network); see the tail.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/bootstrap-venv.sh"
ENVSH="$_repo_root/monitor/locals-env.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$HELPER" ]] || { echo "missing helper: $HELPER" >&2; exit 1; }
[[ -f "$ENVSH" ]]  || { echo "missing env file: $ENVSH" >&2; exit 1; }

# Source the helper in a clean subshell with a seeded PYTHONPATH, a fixed cwd,
# and a temp nexus root, capture the dry-run env + plan. Each call isolated.
run_dry() {
    local cwd="$1" nexroot="$2"; shift 2
    (
        cd "$cwd" || exit 99
        unset NEXUS_ROOT NEXUS_LOCALS
        export PYTHONPATH="/opt/lmod/Python/3.11/lib/python3.11/site-packages"
        # shellcheck disable=SC1090
        source "$HELPER" --dry-run --root "$nexroot" "$@"
        printf 'PYTHONPATH_SET=%s\n' "${PYTHONPATH+yes}"
    )
}

echo "=== nexus-wide dry-run env + plan ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
nex="$WORK/nexus"
proj="$WORK/work/myproj"
mkdir -p "$nex" "$proj"
out=$(run_dry "$proj" "$nex")

# (1) toolchain root is the NEXUS root, NOT the work-project cwd — nexus infra
#     does not extend into work/<project> repos.
if grep -qx "LOCALS=$nex/locals" <<<"$out"; then
    ok "LOCALS pinned to nexus-root/locals (not the work cwd)"
else
    bad "LOCALS pin" "got: $(grep '^LOCALS=' <<<"$out")"
fi

# (2) the per-project venv lives UNDER locals/venvs/ (out of the work repo),
#     keyed by the cwd basename by default.
if grep -qx "VENV=$nex/locals/venvs/myproj" <<<"$out"; then
    ok "venv defaults to locals/venvs/<cwd-basename> (out of work repo)"
else
    bad "venv location" "got: $(grep '^VENV=' <<<"$out")"
fi

# (3) interpreter store / cache / tools all pinned nexus-wide under locals/.
if grep -qx "UV_PYTHON_INSTALL_DIR=$nex/locals/uv/python" <<<"$out" \
   && grep -qx "UV_CACHE_DIR=$nex/locals/uv/cache" <<<"$out" \
   && grep -qx "UV_TOOL_DIR=$nex/locals/uv/tools" <<<"$out"; then
    ok "UV_PYTHON_INSTALL_DIR / UV_CACHE_DIR / UV_TOOL_DIR all -> nexus locals/uv/*"
else
    bad "UV_* pins" "got: $(grep -E '^UV_(PYTHON_INSTALL_DIR|CACHE_DIR|TOOL_DIR)=' <<<"$out")"
fi

# (4) locals/bin is on PATH (tools callable by name).
if grep -qx 'PATH_HAS_LOCALS_BIN=yes' <<<"$out"; then
    ok "locals/bin is on PATH (tools callable by name)"
else
    bad "PATH has locals/bin" "got: $(grep '^PATH_HAS_LOCALS_BIN=' <<<"$out")"
fi

# (5) Lmod PYTHONPATH shadow is cleared.
if grep -qx 'PYTHONPATH_SET=' <<<"$out"; then
    ok "PYTHONPATH unset (Lmod shadow cleared)"
else
    bad "PYTHONPATH unset" "still set: $(grep '^PYTHONPATH_SET=' <<<"$out")"
fi

echo "=== standalone, checksum-pinned uv (no system/home uv) ==="

# (6) uv invoked by ABSOLUTE nexus-local path — never a bare `uv`.
if grep -qx "UV_BIN=$nex/locals/bin/uv" <<<"$out"; then
    ok "uv binary is nexus-local (locals/bin/uv)"
else
    bad "nexus-local uv bin" "got: $(grep '^UV_BIN=' <<<"$out")"
fi

# (7) the plan FETCHES the standalone uv into the shared locals/bin.
if grep -q "PLAN: fetch standalone uv .* -> $nex/locals/bin/uv" <<<"$out"; then
    ok "plan fetches standalone uv into nexus locals/bin"
else
    bad "standalone fetch plan" "plan: $(grep 'PLAN: fetch' <<<"$out")"
fi

# (8) checksum-pinned: a 64-hex sha256 is planned for verify.
if grep -qE 'PLAN: verify sha256 [0-9a-f]{64}$' <<<"$out"; then
    ok "fetch is SHA256-pinned (64-hex checksum)"
else
    bad "checksum pin" "plan: $(grep 'PLAN: verify sha256' <<<"$out")"
fi

# (9) version-pinned download URL (no floating 'latest').
if grep -qE 'PLAN: url https://[^ ]+/releases/download/[0-9]+\.[0-9]+\.[0-9]+/uv-' <<<"$out"; then
    ok "download URL is version-pinned"
else
    bad "version-pinned URL" "plan: $(grep 'PLAN: url' <<<"$out")"
fi

# (10) install/create call the ABSOLUTE nexus uv — no system fallback.
if grep -q "PLAN: $nex/locals/bin/uv python install --no-bin" <<<"$out" \
   && grep -q "PLAN: $nex/locals/bin/uv venv .*--python-preference only-managed" <<<"$out"; then
    ok "uv install/venv use the nexus-local binary + only-managed + --no-bin"
else
    bad "nexus-local uv invocation" "plan: $(grep 'PLAN: .*locals/bin/uv' <<<"$out")"
fi

echo "=== static no-lmod / no-home guarantees (helper + env file) ==="

# (11) neither the helper nor the env file invokes Lmod in CODE.
for f in "$HELPER" "$ENVSH"; do
    code_only=$(grep -vE '^[[:space:]]*#' "$f")
    if grep -qE '\bmodule[[:space:]]+(load|use|purge|swap)\b' <<<"$code_only"; then
        bad "no lmod call ($(basename "$f"))" "found a module invocation in code"
    else
        ok "no \`module load\` in executable code ($(basename "$f"))"
    fi
done

# (12) no code path targets $HOME / ~ / .local/share / .cache for state.
for f in "$HELPER" "$ENVSH"; do
    code_only=$(grep -vE '^[[:space:]]*#' "$f")
    if grep -qE '(\$HOME|/\.local/|/\.cache/uv|~/)' <<<"$code_only"; then
        bad "no home path ($(basename "$f"))" "active code references a home path: $(grep -nE '(\$HOME|/\.local/|/\.cache/uv|~/)' <<<"$code_only" | head -1)"
    else
        ok "no \$HOME / ~ / .local / .cache in executable code ($(basename "$f"))"
    fi
done

echo "=== flag handling ==="

# (13) --python overrides the pinned version end-to-end.
out311=$(run_dry "$proj" "$nex" --python 3.11)
if grep -q "PLAN: $nex/locals/bin/uv venv --python 3.11 " <<<"$out311" \
   && grep -q "PLAN: $nex/locals/bin/uv python install --no-bin 3.11" <<<"$out311"; then
    ok "--python 3.11 threads into both uv calls"
else
    bad "--python override" "plan: $(grep 'PLAN:' <<<"$out311")"
fi

# (14) --name redirects the venv name under locals/venvs/.
outname=$(run_dry "$proj" "$nex" --name fig)
if grep -qx "VENV=$nex/locals/venvs/fig" <<<"$outname"; then
    ok "--name fig -> locals/venvs/fig"
else
    bad "--name override" "got: $(grep '^VENV=' <<<"$outname")"
fi

# (15) --dir gives an explicit in-tree venv (relative resolves against cwd).
outdir=$(run_dry "$proj" "$nex" --dir .venv)
if grep -qx "VENV=$proj/.venv" <<<"$outdir" \
   && grep -qx "PLAN: source $proj/.venv/bin/activate" <<<"$outdir"; then
    ok "--dir .venv -> explicit in-tree venv at cwd"
else
    bad "--dir override" "got: $(grep -E '^VENV=|PLAN: source' <<<"$outdir")"
fi

# (16) --locals redirects the whole toolchain root (e.g. onto scratch).
outloc=$(run_dry "$proj" "$nex" --locals "$nex/alt-locals")
if grep -qx "LOCALS=$nex/alt-locals" <<<"$outloc" \
   && grep -qx "UV_PYTHON_INSTALL_DIR=$nex/alt-locals/uv/python" <<<"$outloc"; then
    ok "--locals redirects the whole toolchain root"
else
    bad "--locals override" "got: $(grep -E '^(LOCALS|UV_PYTHON_INSTALL_DIR)=' <<<"$outloc")"
fi

# (17) BV_UV_TARGET override is honoured (portability to other arch/libc).
outtgt=$(BV_UV_TARGET=aarch64-unknown-linux-musl run_dry "$proj" "$nex")
if grep -q 'PLAN: url .*uv-aarch64-unknown-linux-musl.tar.gz$' <<<"$outtgt"; then
    ok "BV_UV_TARGET overrides the release triple"
else
    bad "BV_UV_TARGET override" "plan: $(grep 'PLAN: url' <<<"$outtgt")"
fi

# (18) $NEXUS_ROOT env is honoured when --root is omitted (the spawn launcher
#      exports it); resolves independent of cwd.
outenv=$(
    cd "$proj" || exit 99
    export NEXUS_ROOT="$nex"
    # shellcheck disable=SC1090
    source "$HELPER" --dry-run --name z
    true
)
if grep -qx "LOCALS=$nex/locals" <<<"$outenv"; then
    ok "\$NEXUS_ROOT env pins the toolchain when --root omitted"
else
    bad "NEXUS_ROOT env resolution" "got: $(grep '^LOCALS=' <<<"$outenv")"
fi

echo "=== simulated fresh-tmpfs interpreter survival (hermetic) ==="

# (19) An interpreter under the nexus tree survives a total $HOME wipe; an
#      interpreter under $HOME would dangle. Fabricate both, wipe a fake $HOME.
sfs="$WORK/sfs"
fakehome="$sfs/home"
interp="$sfs/nexus/locals/uv/python/cpython-stub/bin"
venvbin="$sfs/nexus/locals/venvs/proj/bin"
mkdir -p "$fakehome" "$interp" "$venvbin"
printf '#!/bin/sh\necho PY-OK\n' > "$interp/python3"; chmod +x "$interp/python3"
ln -s "$interp/python3" "$venvbin/python"
rm -rf "$fakehome"; mkdir -p "$fakehome"
if out_sfs=$(HOME="$fakehome" "$venvbin/python" 2>/dev/null) && [[ "$out_sfs" == "PY-OK" ]]; then
    ok "venv interpreter survives a wiped \$HOME (nexus-tree symlink)"
else
    bad "fresh-tmpfs survival" "python did not run after \$HOME wipe (got: ${out_sfs:-<none>})"
fi
homeinterp="$fakehome/.local/uv/bin"; mkdir -p "$homeinterp"
printf '#!/bin/sh\necho PY-OK\n' > "$homeinterp/python3"; chmod +x "$homeinterp/python3"
ln -s "$homeinterp/python3" "$venvbin/python-home"
rm -rf "$fakehome"; mkdir -p "$fakehome"
if HOME="$fakehome" "$venvbin/python-home" 2>/dev/null; then
    bad "negative control" "a \$HOME-resident interpreter unexpectedly survived the wipe"
else
    ok "negative control: a \$HOME-resident interpreter DOES dangle (why we avoid it)"
fi

# --- OPT-IN live end-to-end proof (network) ----------------------------
# Real download + checksum + interpreter provision for TWO projects sharing
# one nexus toolchain, then a $HOME wipe, then assert both pythons still run
# AND nothing leaked into $HOME AND the work dirs stayed empty. Skipped unless
# BV_LIVE_TEST=1 so the default suite stays hermetic.
if [[ "${BV_LIVE_TEST:-0}" == "1" ]]; then
    echo "=== LIVE end-to-end, shared nexus toolchain (BV_LIVE_TEST=1) ==="
    live="$WORK/live"; lnex="$live/nexus"; lhome="$live/home"
    mkdir -p "$lnex" "$live/projA" "$live/projB" "$lhome"
    boot() { ( cd "$1"; export HOME="$lhome" NEXUS_ROOT="$lnex"; source "$HELPER" --python 3.12 ); }
    if boot "$live/projA" >"$live/a.log" 2>&1 && boot "$live/projB" >"$live/b.log" 2>&1; then
        # one shared uv + one shared interpreter, two distinct venvs
        ucount=$(ls "$lnex"/locals/uv/python 2>/dev/null | wc -l)
        [[ -x "$lnex/locals/bin/uv" && "$ucount" -ge 1 ]] \
            && ok "live: shared standalone uv + interpreter under nexus locals" \
            || bad "live shared toolchain" "uv or interpreter missing (cpython dirs=$ucount)"
        rm -rf "$lhome"; mkdir -p "$lhome"
        if HOME="$lhome" "$lnex/locals/venvs/projA/bin/python" -c 'print("A")' 2>/dev/null | grep -qx A \
           && HOME="$lhome" "$lnex/locals/venvs/projB/bin/python" -c 'print("B")' 2>/dev/null | grep -qx B; then
            ok "live: both project pythons survive a wiped \$HOME"
        else
            bad "live fresh-tmpfs" "a venv python failed after \$HOME wipe"
        fi
        leak=$(find "$lhome" -type f 2>/dev/null | head)
        [[ -z "$leak" ]] && ok "live: zero files written into \$HOME" \
                         || bad "no home writes" "files in \$HOME: $leak"
        wleak=$(find "$live/projA" "$live/projB" -mindepth 1 2>/dev/null | head)
        [[ -z "$wleak" ]] && ok "live: work dirs stayed empty (no infra in work repos)" \
                          || bad "work-repo leak" "files in work dirs: $wleak"
    else
        bad "live bootstrap" "a bootstrap failed; logs: $(tail -2 "$live/a.log" 2>/dev/null; tail -2 "$live/b.log" 2>/dev/null)"
    fi
else
    echo "(skipping live end-to-end; set BV_LIVE_TEST=1 to run the network proof)"
fi

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
