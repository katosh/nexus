#!/usr/bin/env bash
# Tests for monitor/pipwrap/pip — the PATH-front fork-storm pip guard
# (fork-storm class, your-org/nexus-code#487).
#
# The 2026-07-09 node-down: a worker's `pip download …` hit the
# agent-sandbox wrapper at /app/bin/pip, which re-execs itself without
# bound — 10,242 pip processes, pid_max exhausted, watcher dead. The
# shim under test refuses exactly that resolution and points at
# `uv pip`, while passing through every non-hazardous pip (an activated
# venv's own bin/pip), WATCHER_WINDOW environments, and the loud
# PIP_UNWRAPPED=1 opt-in.
#
# Hermetic: the "hazardous" pip is a stub under $WORK/app/bin selected
# via NEXUS_PIP_HAZARD_PREFIX (the shim's test seam; production default
# /app/). Executing a stub writes a marker file, so "was the real pip
# reached" is asserted on the filesystem, not on output parsing.
#
# Run: bash monitor/watcher/test-pip-shim.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHIM_DIR=$(cd "$_test_dir/../pipwrap" 2>/dev/null && pwd) || {
    echo "FAIL: monitor/pipwrap/ missing — pip shim not installed (your-org/nexus-code#487)" >&2
    echo "FAILED"
    exit 1
}
[[ -x "$SHIM_DIR/pip" ]] || {
    echo "FAIL: monitor/pipwrap/pip missing or not executable" >&2
    echo "FAILED"
    exit 1
}

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q in <<%s>>\n' "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

WORK=$(mktemp -d -t nexus-pip-shim-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Hazardous stub (models /app/bin/pip — but only via the prefix seam;
# it never recurses, so the test cannot storm).
HAZ="$WORK/app/bin"
mkdir -p "$HAZ"
cat > "$HAZ/pip" <<EOF
#!/bin/bash
echo "hazard-pip ran: \$*" > "$WORK/hazard-ran.marker"
echo "HAZARD_PIP \$*"
EOF
chmod +x "$HAZ/pip"
ln -s pip "$HAZ/pip3"

# Venv-style safe pip (outside the hazard prefix).
VENV="$WORK/venv/bin"
mkdir -p "$VENV"
cat > "$VENV/pip" <<EOF
#!/bin/bash
echo "venv-pip ran: \$*" > "$WORK/venv-ran.marker"
echo "VENV_PIP \$*"
EOF
chmod +x "$VENV/pip"

# Synthetic PATHs. The shim + stubs are bash scripts needing the system
# dirs; the trailing real /app/bin (when present) keeps
# command_not_found.py resolvable on this synthetic PATH — the #479
# fork-bomb precondition guard. It is LAST, so it never wins a pip
# resolution over the fixture dirs.
TAIL="/usr/bin:/bin"
[[ -d /app/bin ]] && TAIL="$TAIL:/app/bin"
P_HAZ="$SHIM_DIR:$HAZ:$TAIL"
P_VENV="$SHIM_DIR:$VENV:$HAZ:$TAIL"

run_shim() {  # run_shim <path> <cmd-name> [env VAR=val ...] -- [args...]
    local p="$1" name="$2"; shift 2
    local -a envs=()
    while (( $# > 0 )); do
        case "$1" in
            --) shift; break ;;
            *)  envs+=("$1"); shift ;;
        esac
    done
    OUT=$(env -u PIP_UNWRAPPED -u WATCHER_WINDOW \
              NEXUS_PIP_HAZARD_PREFIX="$WORK/app/" PATH="$p" \
              ${envs[@]+"${envs[@]}"} "$name" "$@" 2>&1)
    RC=$?
}

# ---- 1. hazardous resolution is refused ----------------------------------

echo '=== bare pip resolving to the hazardous wrapper is refused, loudly ==='
rm -f "$WORK/hazard-ran.marker"
run_shim "$P_HAZ" pip -- download dandelion --no-deps
assert_eq       "refusal exits 1"                    "$RC" "1"
assert_contains "refusal names uv pip"               "$OUT" "uv pip"
assert_contains "refusal cites the class issue"      "$OUT" "your-org/nexus-code#487"
assert_contains "refusal names the escape hatch"     "$OUT" "PIP_UNWRAPPED=1"
assert_eq       "hazardous pip was NOT executed"     "$([[ -f $WORK/hazard-ran.marker ]] && echo ran || echo no)" "no"

echo '=== pip3 (symlink) behaves identically ==='
rm -f "$WORK/hazard-ran.marker"
run_shim "$P_HAZ" pip3 -- install requests
assert_eq       "pip3 refusal exits 1"               "$RC" "1"
assert_eq       "hazardous pip3 was NOT executed"    "$([[ -f $WORK/hazard-ran.marker ]] && echo ran || echo no)" "no"

# ---- 2. escape hatches ----------------------------------------------------

echo '=== PIP_UNWRAPPED=1 is a deliberate, loud passthrough ==='
rm -f "$WORK/hazard-ran.marker"
run_shim "$P_HAZ" pip PIP_UNWRAPPED=1 -- install requests
assert_eq       "opt-in exits via the real pip"      "$RC" "0"
assert_contains "real pip received the argv"         "$OUT" "HAZARD_PIP install requests"
assert_eq       "hazardous pip WAS executed"         "$([[ -f $WORK/hazard-ran.marker ]] && echo ran || echo no)" "ran"

echo '=== WATCHER_WINDOW environments pass through (ghwrap parity) ==='
rm -f "$WORK/hazard-ran.marker"
run_shim "$P_HAZ" pip WATCHER_WINDOW=headless -- --version
assert_eq       "watcher passthrough exits 0"        "$RC" "0"
assert_eq       "watcher passthrough reached real pip" "$([[ -f $WORK/hazard-ran.marker ]] && echo ran || echo no)" "ran"

# ---- 3. non-hazardous pips are untouched ----------------------------------

echo '=== a venv-style pip (outside the hazard prefix) passes through ==='
rm -f "$WORK/venv-ran.marker" "$WORK/hazard-ran.marker"
run_shim "$P_VENV" pip -- install -e .
assert_eq       "venv pip exits 0"                   "$RC" "0"
assert_contains "venv pip received the argv"         "$OUT" "VENV_PIP install -e ."
assert_eq       "hazardous pip untouched"            "$([[ -f $WORK/hazard-ran.marker ]] && echo ran || echo no)" "no"

# ---- 4. operator / services scoping is structural --------------------------
# locals-env.sh fronts pipwrap in FULL mode only; PATH-ONLY mode (the
# operator's interactive shells) returns before the wrapper blocks.
echo '=== PATH-only mode (operator shells) never fronts the shim ==='
op_path=$(env -i HOME="$HOME" PATH="/usr/bin:/bin" NEXUS_LOCALS_PATH_ONLY=1 \
    bash -c ". '$_test_dir/../locals-env.sh'; printf '%s' \"\$PATH\"")
case "$op_path" in
    *pipwrap*) assert_eq "PATH-only mode fronts pipwrap (must not)" "fronted" "absent" ;;
    *)         assert_eq "PATH-only mode leaves pipwrap off PATH"   "absent"  "absent" ;;
esac
echo '=== full mode (agent shells) fronts the shim ==='
ag_path=$(env -i HOME="$HOME" PATH="/usr/bin:/bin" \
    bash -c ". '$_test_dir/../locals-env.sh'; printf '%s' \"\$PATH\"")
case "$ag_path" in
    *pipwrap*) assert_eq "full mode fronts pipwrap" "fronted" "fronted" ;;
    *)         assert_eq "full mode fronts pipwrap" "absent"  "fronted" ;;
esac

# ---- summary --------------------------------------------------------------

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
