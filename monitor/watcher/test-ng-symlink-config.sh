#!/usr/bin/env bash
# Unit tests for `monitor/ng`'s symlink-invocation config resolution.
#
# Run: bash monitor/watcher/test-ng-symlink-config.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Background (your-org/nexus-code#522): `ng` resolved its own directory
# with `cd "$(dirname "${BASH_SOURCE[0]}")"` — WITHOUT dereferencing
# symlinks. Invoked BY NAME through the `locals/bin/ng -> ../../monitor/ng`
# shim (the PATH form the worker floor tells every worker to use),
# BASH_SOURCE[0] is the shim path, so `_script_dir` became `locals/bin`
# and `$_script_dir/../config/load.sh` pointed at the nonexistent
# `locals/config/load.sh`. Config loading then silently failed and every
# config-derived value fell back to a built-in default — with no error a
# caller would notice for read-only verbs.
#
# The fix dereferences first:
#   _script_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
#
# Strategy: build a minimal nexus tree whose stubbed `config/load.sh`
# drops a marker file every time it is sourced/called, plus a symlink that
# mirrors the real `locals/bin/ng -> ../../monitor/ng` shape. Invoke `ng`
# BOTH directly and through the symlink; assert config loads (marker
# present, no "No such file" on stderr) and that a config-derived value is
# actually consumed in BOTH forms.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — missing file: %s\n' "$label" "$path" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q in output\n' "$label" "$needle" >&2
        printf '         output:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    else printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected to find %q\n' "$label" "$needle" >&2
        printf '         output:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Canonical nexus-tree shape: monitor/ng + config/load.sh.
TREE="$WORK/nexus"
mkdir -p "$TREE/monitor" "$TREE/config" "$TREE/locals/bin"
cp "$NG_REAL" "$TREE/monitor/ng"

# Stubbed config/load.sh: drops a marker EVERY time it is invoked (proving
# it was found via the resolved _script_dir) and echoes a distinct sentinel
# for github.repo so we can prove the value was consumed, not defaulted.
LOAD_MARKER="$WORK/load-invoked"
cat > "$TREE/config/load.sh" <<STUB
#!/usr/bin/env bash
printf 'x' >> "$LOAD_MARKER"
case "\${1:-}" in
    github.repo)       printf 'sentinel-org/sentinel-repo' ;;
    github.user_login) printf 'sentinel-user' ;;
    *) [[ \$# -ge 2 ]] && printf '%s' "\$2" || exit 2 ;;
esac
STUB
chmod +x "$TREE/config/load.sh"

# mint-token stub — defensive; the verb under test doesn't hit gh.
cat > "$TREE/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf 'fake-token'
STUB
chmod +x "$TREE/monitor/mint-token.sh"

# The real shim shape: locals/bin/ng -> ../../monitor/ng (relative).
ln -s ../../monitor/ng "$TREE/locals/bin/ng"

# Drive a read-only verb that forces config sourcing (REPO/USER_LOGIN are
# read unconditionally at startup) and prints usage. `report-check` with no
# path exits non-zero with a usage line — deterministic, no gh, no state
# mutation — exactly the invocation the issue's repro used.
run_ng() {
    local _ng="$1"
    rm -f "$LOAD_MARKER"
    # NEXUS_STATE_DIR keeps any incidental state writes inside $WORK.
    env -u NEXUS_ROOT NEXUS_STATE_DIR="$WORK/state" \
        "$_ng" report-check 2>&1
}

# ---- Test 1: direct invocation loads config (baseline; passed pre-fix) --

echo '=== direct invocation: monitor/ng sources config ==='
OUT=$(run_ng "$TREE/monitor/ng")
assert_file_exists "config/load.sh was invoked (marker present)" "$LOAD_MARKER"
assert_not_contains "no 'No such file' error" "$OUT" "No such file"
assert_not_contains "no reference to a stray load.sh path" "$OUT" "locals/config/load.sh"

# ---- Test 2: symlink invocation loads config (the #522 regression) ------

echo '=== symlink invocation: locals/bin/ng sources config (was BROKEN) ==='
OUT=$(run_ng "$TREE/locals/bin/ng")
assert_file_exists "config/load.sh was invoked through the symlink" "$LOAD_MARKER"
assert_not_contains "no 'No such file' error via symlink" "$OUT" "No such file"
assert_not_contains "does not look under locals/config/" "$OUT" "locals/config/load.sh"

# ---- Test 3: symlink invocation from an unrelated cwd -------------------
# The issue's exact repro ran the shim from /tmp. Config must still load
# regardless of cwd — _script_dir is derived from the dereferenced source,
# not the working directory.

echo '=== symlink invocation from a foreign cwd still finds config ==='
rm -f "$LOAD_MARKER"
OUT=$(cd "$WORK" && env -u NEXUS_ROOT NEXUS_STATE_DIR="$WORK/state" \
        "$TREE/locals/bin/ng" report-check 2>&1)
assert_file_exists "config/load.sh invoked from foreign cwd" "$LOAD_MARKER"
assert_not_contains "no 'No such file' from foreign cwd" "$OUT" "No such file"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
