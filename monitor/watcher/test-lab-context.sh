#!/usr/bin/env bash
# Unit tests for monitor/_lab-context.sh — deterministic env probes that
# the bootstrap consults to decide whether to offer the OPTIONAL, site-
# specific HPC skills bundle + labsh addons.
#
# Each probe must:
#   * exit 0 always (idempotent observation, not a gate)
#   * emit one line `key=value` to stdout
#   * stay offline-only (no network calls; org-membership probing is the
#     install-prompt agent's job, not the bash layer's)
#
# Strategy: production logic anchors on three platform-dependent inputs
#   1. configured HPC mount + hostname prefix → HPC
#   2. ~/.claude/skills/<bundle> (symlink OR directory) → hpc-skills
#   3. $SANDBOX_PROJECT_DIR/work/labsh OR `labsh` on PATH → labsh
# Each input is overridable via a documented `_NEXUS_*` env hook so the
# tests drive them deterministically from a tmpdir, without touching a
# real cluster mount or pretending to be on an HPC node.
#
# Run: bash monitor/watcher/test-lab-context.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LAB_CTX="$_test_dir/../_lab-context.sh"

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

WORK=$(mktemp -d -t nexus-lab-context-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Run one probe in a fresh subshell with caller-supplied env exports.
# Subshell isolation keeps probe-internal globals from leaking across
# scenarios. `envs` is a multi-line string of `export VAR=...` lines.
#
# `unset -f command_not_found_handle` guards against the TDD-red phase:
# if the lib doesn't exist yet, the called function is missing, and
# Debian-family hosts' bashrc-defined handle runs apt lookups that can
# stall the subshell for tens of seconds. Defusing it here keeps the
# red signal fast.
probe() {
    local fn="$1" envs="$2"
    bash -c "
set -uo pipefail
unset -f command_not_found_handle 2>/dev/null
$envs
. '$LAB_CTX' 2>/dev/null || true
$fn 2>/dev/null
"
}

# Reusable PATH-without-labsh: a fresh empty dir prepended to the system
# bin paths. We can't drop to /tmp/empty alone — bash's command-not-found
# handler resolves via the system path on Debian-family hosts and stalls
# under empty PATH (apt-cache lookups), so keep /usr/bin:/bin available.
empty_path_dir="$WORK/empty-path"
mkdir -p "$empty_path_dir"
SAFE_NO_LABSH_PATH="$empty_path_dir:/usr/bin:/bin"

# --- nexus_detect_hpc --------------------------------------------------

echo '=== nexus_detect_hpc: HPC mount AND hostname prefix ==='

HPC_PREFIXES='login|gpu|compute'

# Case: mount missing → hpc=0 even with a matching hostname
out=$(probe nexus_detect_hpc "
export _NEXUS_HPC_MOUNT='$WORK/no-such-mount'
export _NEXUS_HPC_HOST_PREFIXES='$HPC_PREFIXES'
export _NEXUS_HOSTNAME='login01'
")
assert_eq "missing mount + login → hpc=0" "$out" "hpc=0"

# Case: mount present but hostname is not a known cluster prefix
mount_present="$WORK/hpc-mount"
mkdir -p "$mount_present"
out=$(probe nexus_detect_hpc "
export _NEXUS_HPC_MOUNT='$mount_present'
export _NEXUS_HPC_HOST_PREFIXES='$HPC_PREFIXES'
export _NEXUS_HOSTNAME='laptop-1234'
")
assert_eq "mount + hostname=laptop → hpc=0" "$out" "hpc=0"

# Case: mount present but no prefixes configured → hpc=0 (generic host)
out=$(probe nexus_detect_hpc "
export _NEXUS_HPC_MOUNT='$mount_present'
export _NEXUS_HOSTNAME='login01'
")
assert_eq "mount + unset prefixes → hpc=0" "$out" "hpc=0"

# Case: both signals → hpc=1, across each accepted prefix and bare form
for host in login login01 gpu gpu07 compute compute-node-1; do
    out=$(probe nexus_detect_hpc "
export _NEXUS_HPC_MOUNT='$mount_present'
export _NEXUS_HPC_HOST_PREFIXES='$HPC_PREFIXES'
export _NEXUS_HOSTNAME='$host'
")
    assert_eq "mount + hostname=$host → hpc=1" "$out" "hpc=1"
done

# Case: empty hostname is treated as 'no match' (defensive vs nonsense)
out=$(probe nexus_detect_hpc "
export _NEXUS_HPC_MOUNT='$mount_present'
export _NEXUS_HPC_HOST_PREFIXES='$HPC_PREFIXES'
export _NEXUS_HOSTNAME=''
")
assert_eq "mount + empty hostname → hpc=0" "$out" "hpc=0"

# --- nexus_detect_hpc_skills_installed ---------------------------------

echo '=== nexus_detect_hpc_skills_installed: ~/.claude/skills/hpc-skills ==='

# Case: no entry at all → installed=0
home_empty="$WORK/home-empty"
mkdir -p "$home_empty/.claude/skills"
out=$(probe nexus_detect_hpc_skills_installed "
export HOME='$home_empty'
")
assert_eq "no hpc-skills entry → installed=0" "$out" "installed=0"

# Case: symlink (the documented + sandbox-correct pattern) → installed=1
home_symlink="$WORK/home-symlink"
mkdir -p "$home_symlink/.claude/skills" "$home_symlink/.claude/hpc-skills/skills"
ln -s "$home_symlink/.claude/hpc-skills/skills" \
    "$home_symlink/.claude/skills/hpc-skills"
out=$(probe nexus_detect_hpc_skills_installed "
export HOME='$home_symlink'
")
assert_eq "symlink at skills/hpc-skills → installed=1" "$out" "installed=1"

# Case: plain directory (operator hand-managed it) → installed=1
home_dir="$WORK/home-dir"
mkdir -p "$home_dir/.claude/skills/hpc-skills"
out=$(probe nexus_detect_hpc_skills_installed "
export HOME='$home_dir'
")
assert_eq "direct directory at skills/hpc-skills → installed=1" "$out" "installed=1"

# Case: dangling symlink — `-L` matches even when target is gone. We
# treat that as "installed" by convention (the operator put it there
# on purpose; cleanup is their job, not ours).
home_dangling="$WORK/home-dangling"
mkdir -p "$home_dangling/.claude/skills"
ln -s "$home_dangling/does-not-exist" \
    "$home_dangling/.claude/skills/hpc-skills"
out=$(probe nexus_detect_hpc_skills_installed "
export HOME='$home_dangling'
")
assert_eq "dangling symlink → installed=1" "$out" "installed=1"

# --- nexus_detect_labsh_installed --------------------------------------

echo '=== nexus_detect_labsh_installed: project-local dir OR PATH binary ==='

# Case: neither dir nor binary → installed=0
sandbox_empty="$WORK/sandbox-empty"
mkdir -p "$sandbox_empty/work"
out=$(probe nexus_detect_labsh_installed "
export SANDBOX_PROJECT_DIR='$sandbox_empty'
export PATH='$SAFE_NO_LABSH_PATH'
")
assert_eq "no labsh dir, no labsh on PATH → installed=0" "$out" "installed=0"

# Case: project-local clone present → installed=1
sandbox_with_dir="$WORK/sandbox-with-labsh"
mkdir -p "$sandbox_with_dir/work/labsh"
out=$(probe nexus_detect_labsh_installed "
export SANDBOX_PROJECT_DIR='$sandbox_with_dir'
export PATH='$SAFE_NO_LABSH_PATH'
")
assert_eq "\$SANDBOX_PROJECT_DIR/work/labsh present → installed=1" "$out" "installed=1"

# Case: labsh on PATH (system install / homebrew tap) → installed=1
sandbox_no_dir="$WORK/sandbox-no-dir"
mkdir -p "$sandbox_no_dir/work"
path_with_labsh="$WORK/path-with-labsh"
mkdir -p "$path_with_labsh"
cat > "$path_with_labsh/labsh" <<'SHIM'
#!/usr/bin/env bash
echo 'labsh stub'
SHIM
chmod +x "$path_with_labsh/labsh"
out=$(probe nexus_detect_labsh_installed "
export SANDBOX_PROJECT_DIR='$sandbox_no_dir'
export PATH='$path_with_labsh:/usr/bin:/bin'
")
assert_eq "labsh binary on PATH → installed=1" "$out" "installed=1"

# Case: SANDBOX_PROJECT_DIR unset must not crash (defensive — bootstrap
# does set it via the agent-sandbox launch, but the probe library is
# also sourced from install-prompt.md's bash blocks at later phases
# where the var's lifetime is fuzzier).
out=$(probe nexus_detect_labsh_installed "
unset SANDBOX_PROJECT_DIR
export PATH='$SAFE_NO_LABSH_PATH'
")
assert_eq "unset SANDBOX_PROJECT_DIR + empty PATH → installed=0" "$out" "installed=0"

# --- summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
