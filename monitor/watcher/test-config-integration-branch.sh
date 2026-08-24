#!/usr/bin/env bash
# Unit tests for the shared integration-branch resolver
# (`monitor/_integration_branch.sh`, your-org/nexus-code#763).
#
# Run: bash monitor/watcher/test-config-integration-branch.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE CASE THAT MATTERS is M1: an operator config carrying ONLY the
# deprecated `monitor.clone_drift.branch`, with a NON-DEFAULT value, must
# still resolve to that value. `config/nexus.yml` is per-operator and not
# tracked in this repo, so a bare rename lands on every clone as a silent
# default-fallback — the operator who deliberately set `release` gets
# `dev`, nothing errors, and the wrong branch feeds the deployment gate.
#
# M1-CONTROL is the other half and is what makes M1 a property test
# rather than a smoke test: it runs the NAIVE rename — `load.sh
# monitor.integration_branch dev` — against the SAME fixture and asserts
# it answers `dev`. Without the control, M1 passes for any implementation
# that happens to read the old key, including one that would regress the
# moment somebody "simplified" the lookup by passing a default. The
# control pins the failure it is defending against, in-suite, forever.
#
# The REAL `config/load.sh` is used throughout, never a stub. The whole
# resolver turns on load.sh's exit codes (0 present / 2 absent / other
# "could not look"), and a stub would replay the author's belief about
# those rather than the loader's behaviour.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

MONITOR_DIR=$(cd "$_test_dir/.." && pwd)
REPO_ROOT=$(cd "$MONITOR_DIR/.." && pwd)
RESOLVER="$MONITOR_DIR/_integration_branch.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "SKIP: python3 + pyyaml unavailable; config/load.sh cannot run" >&2
    exit 0
fi

# ---- fixture -------------------------------------------------------------

# make_root <name> [yaml-body…] — a nexus root carrying the REAL
# config/load.sh and a nexus.yml built from the supplied `monitor:` keys.
# With no keys, nexus.yml holds an unrelated key so the file exists and
# parses but neither branch key is present.
make_root() {
    local name="$1"; shift
    local root="$WORK/$name"
    mkdir -p "$root/config"
    cp "$REPO_ROOT/config/load.sh" "$root/config/load.sh"
    chmod +x "$root/config/load.sh"
    {
        echo "monitor:"
        echo "  interval_seconds: 60"
        local line
        for line in "$@"; do printf '  %s\n' "$line"; done
    } > "$root/config/nexus.yml"
    printf '%s' "$root"
}

# resolve_env <root> [VAR=VAL…] — run the resolver in a CLEAN subshell
# (fresh once-per-process note state, no leaked env) against <root>.
# stdout: "<branch>|<source>|<stderr-notes>"
#
# Uses `nexus_integration_branch_tsv`, which carries the provenance on
# STDOUT. `$(nexus_integration_branch)` is a subshell, so the function's
# assignment to $NEXUS_INTEGRATION_BRANCH_SOURCE would be discarded and every
# `source=` assertion below would compare "" against "" — passing for an
# implementation that reports nothing at all. That is not a hypothetical: the
# first version of this suite hit it, and so did `_config.sh`.
resolve_env() (
    local root="$1"; shift
    unset MONITOR_INTEGRATION_BRANCH MONITOR_CLONE_DRIFT_BRANCH
    unset NEXUS_CONFIG NEXUS_INTEGRATION_BRANCH_QUIET
    export NEXUS_ROOT="$root"
    local kv
    for kv in "$@"; do export "${kv?}"; done
    local errf="$WORK/err.$$" tsv
    # shellcheck source=../_integration_branch.sh
    source "$RESOLVER"
    tsv=$(nexus_integration_branch_tsv 2>"$errf")
    printf '%s|%s|%s' "${tsv%%	*}" "${tsv##*	}" "$(tr '\n' ' ' < "$errf")"
    rm -f "$errf"
)

resolve() { resolve_env "$1"; }

# load_rc <root> <key> — `config/load.sh <key>` with NO default, against
# <root> and nothing else. $NEXUS_ROOT MUST be pinned: load.sh resolves
# its config through it, and this suite runs inside a live nexus whose
# own config/nexus.yml would otherwise answer instead of the fixture.
load_rc() (
    unset NEXUS_CONFIG
    export NEXUS_ROOT="$1"
    "$1/config/load.sh" "$2" >/dev/null 2>&1
)

f_branch() { cut -d'|' -f1 <<<"$1"; }
f_source() { cut -d'|' -f2 <<<"$1"; }
f_notes()  { cut -d'|' -f3- <<<"$1"; }

# ===========================================================================
echo "== M1: THE MIGRATION CASE — old key only, NON-DEFAULT value =="
# ===========================================================================

ROOT=$(make_root m1 "clone_drift:" "  branch: release")
R=$(resolve "$ROOT")

assert_eq "old-key-only, non-default value SURVIVES the rename" \
    "$(f_branch "$R")" "release"
assert_eq "  …and the resolver says which rung answered" \
    "$(f_source "$R")" "config-clone-drift-deprecated"
assert_contains "  …LOUDLY: the note names the deprecated key" \
    "$(f_notes "$R")" "monitor.clone_drift.branch"
assert_contains "  …names the canonical replacement" \
    "$(f_notes "$R")" "monitor.integration_branch"
assert_contains "  …and quotes the value it honoured, so a reader can verify" \
    "$(f_notes "$R")" "release"

# --- M1-CONTROL. The naive rename, run against the SAME fixture. -----------
# `load.sh <key> <default>` cannot distinguish "absent" from "set to the
# default": it prints `dev` for both, so a resolver written that way never
# reaches the old key. This is the exact failure M1 defends against, and
# asserting it here keeps M1 honest.
naive=$(NEXUS_ROOT="$ROOT" "$ROOT/config/load.sh" monitor.integration_branch dev 2>/dev/null)
assert_eq "CONTROL: the NAIVE rename (load.sh key default) answers 'dev' — the silent bug" \
    "$naive" "dev"
assert_eq "CONTROL: …while the shipped resolver answers 'release' on the same config" \
    "$(f_branch "$R")" "release"

# --- M1-MECHANISM. rc 2 is what licenses the fall-through. -----------------
load_rc "$ROOT" monitor.integration_branch; rc=$?
assert_eq "load.sh exits 2 for an ABSENT key when no default is supplied" "$rc" "2"
load_rc "$ROOT" monitor.clone_drift.branch; rc=$?
assert_eq "load.sh exits 0 for a PRESENT key" "$rc" "0"

# ===========================================================================
echo
echo "== M2: the canonical key =="
# ===========================================================================

ROOT=$(make_root m2 "integration_branch: release")
R=$(resolve "$ROOT")
assert_eq "new key alone resolves"            "$(f_branch "$R")" "release"
assert_eq "  …reported as config-integration" "$(f_source "$R")" "config-integration"
assert_not_contains "  …with NO deprecation note (nothing is deprecated here)" \
    "$(f_notes "$R")" "DEPRECATED"

# ===========================================================================
echo
echo "== M3: both keys — new wins, and a disagreement is never silent =="
# ===========================================================================

ROOT=$(make_root m3a "integration_branch: release" "clone_drift:" "  branch: release")
R=$(resolve "$ROOT")
assert_eq "both keys, SAME value → new wins" "$(f_branch "$R")" "release"
assert_contains "  …and the redundant old key is called out" \
    "$(f_notes "$R")" "delete the old key"

ROOT=$(make_root m3b "integration_branch: release" "clone_drift:" "  branch: main")
R=$(resolve "$ROOT")
assert_eq "both keys, DIFFERENT values → new wins" "$(f_branch "$R")" "release"
assert_contains "  …and the conflict is LOUD, not resolved in silence" \
    "$(f_notes "$R")" "CONFLICT"
assert_contains "  …naming both values so the operator can see the drift" \
    "$(f_notes "$R")" "main"
# The whole reason #754 refused to mint a second key: two records of one
# property drift apart. Mid-migration an operator CAN create that state by
# hand, and the resolver must report it rather than quietly picking.
assert_contains "  …and says why two records is the problem" \
    "$(f_notes "$R")" "drift"

# ===========================================================================
echo
echo "== M4: neither key — 'dev', and it is a DEFAULT, not a reading =="
# ===========================================================================

ROOT=$(make_root m4)
R=$(resolve "$ROOT")
assert_eq "neither key → dev"                    "$(f_branch "$R")" "dev"
assert_eq "  …reported as source=default"        "$(f_source "$R")" "default"
assert_not_contains "  …no conflict note fabricated from two absences" \
    "$(f_notes "$R")" "CONFLICT"

# ===========================================================================
echo
echo "== M5: 'could not look' is NOT 'you configured dev' =="
# ===========================================================================
# #740's thesis. A root with no config/load.sh at all resolves to the same
# STRING as M4 but must not resolve to the same CLAIM: M4 read your config
# and found nothing; M5 never read anything. Collapsing the two is how a
# missing config file comes to look like a deliberate setting.

ROOT="$WORK/m5"; mkdir -p "$ROOT"
R=$(resolve "$ROOT")
assert_eq "unreadable config still yields a usable branch" "$(f_branch "$R")" "dev"
assert_eq "  …but the SOURCE distinguishes it from a real default" \
    "$(f_source "$R")" "default-unreadable-config"
assert_contains "  …and it says so out loud" "$(f_notes "$R")" "GUESS"
# The distinguishing assertion: same value, different reported claim.
m4=$(resolve "$(make_root m5ctl)")
assert_eq "CONTROL: M4 and M5 agree on the VALUE…" \
    "$(f_branch "$R")" "$(f_branch "$m4")"
assert_eq "…and DISAGREE on the claim, which is the whole point" \
    "$([[ "$(f_source "$R")" != "$(f_source "$m4")" ]] && echo differ || echo same)" \
    "differ"

# ===========================================================================
echo
echo "== M6: env precedence =="
# ===========================================================================

ROOT=$(make_root m6 "integration_branch: cfg-new" "clone_drift:" "  branch: cfg-old")

R=$(resolve_env "$ROOT" "MONITOR_INTEGRATION_BRANCH=env-new")
assert_eq "canonical env beats both config keys" "$(f_branch "$R")" "env-new"
assert_eq "  …source=env-integration"            "$(f_source "$R")" "env-integration"

R=$(resolve_env "$ROOT" "MONITOR_CLONE_DRIFT_BRANCH=env-old")
assert_eq "DEPRECATED env is still honoured (the watcher + every fixture set it)" \
    "$(f_branch "$R")" "env-old"
assert_eq "  …source names it as deprecated" \
    "$(f_source "$R")" "env-clone-drift-deprecated"
assert_contains "  …and notes the deprecation" "$(f_notes "$R")" "DEPRECATED"

R=$(resolve_env "$ROOT" "MONITOR_INTEGRATION_BRANCH=env-new" "MONITOR_CLONE_DRIFT_BRANCH=env-old")
assert_eq "canonical env beats deprecated env" "$(f_branch "$R")" "env-new"

# ===========================================================================
echo
echo "== M7: an EMPTY value is not a value =="
# ===========================================================================
# `monitor.integration_branch:` with nothing after it parses as null and
# load.sh prints "None"… so the fixture uses an explicit empty string,
# which is the shape an operator actually produces. An empty branch is
# unusable; treating it as "present" would shadow a perfectly good old key
# with nothing at all.

ROOT=$(make_root m7 'integration_branch: ""' "clone_drift:" "  branch: release")
R=$(resolve "$ROOT")
assert_eq "empty new key falls through to the old key, not to ''" \
    "$(f_branch "$R")" "release"
assert_contains "  …and says the key was present but empty" \
    "$(f_notes "$R")" "EMPTY"

# ===========================================================================
echo
echo "== M8: ONE CLAIMANT, enforced by construction =="
# ===========================================================================
# The property #754 protected with a comment. Both consumers must now
# produce the SAME answer from the SAME config without either re-deriving
# the chain — so the check is behavioural: drive each consumer's own
# resolution path and compare.

ROOT=$(make_root m8 "clone_drift:" "  branch: release")

# Consumer 1 — the cc-auto-update deployment gate's named seam.
gate=$(
    unset MONITOR_INTEGRATION_BRANCH MONITOR_CLONE_DRIFT_BRANCH NEXUS_CONFIG
    export NEXUS_ROOT="$ROOT" NEXUS_INTEGRATION_BRANCH_QUIET=1
    # `_gate_integration_branch` is defined mid-file in a script whose
    # dispatch runs on source, so extract and evaluate just that function
    # together with the resolver it must delegate to.
    source "$RESOLVER"
    eval "$(awk '/^_gate_integration_branch\(\) \{/,/^\}/' "$MONITOR_DIR/cc-auto-update-apply.sh")"
    _gate_integration_branch
)
assert_eq "consumer 1 (cc-auto-update gate) resolves the operator's value" \
    "$gate" "release"

# Consumer 2 — the watcher's clone-drift detector, via the module the
# watcher actually sources.
drift=$(
    unset MONITOR_INTEGRATION_BRANCH MONITOR_CLONE_DRIFT_BRANCH NEXUS_CONFIG
    export NEXUS_ROOT="$ROOT" NEXUS_INTEGRATION_BRANCH_QUIET=1
    source "$_test_dir/_clone_drift.sh"
    nexus_integration_branch
)
assert_eq "consumer 2 (clone-drift detector) resolves the same value" \
    "$drift" "release"
assert_eq "the two consumers AGREE — one claimant, by construction" "$gate" "$drift"

# The structural half: neither consumer may hold a private lookup. A
# second `load.sh monitor.clone_drift.branch` or a bare `:-dev` in either
# file is a second claimant re-appearing.
leaks=$(grep -n 'clone_drift\.branch\|MONITOR_CLONE_DRIFT_BRANCH:-dev' \
            "$MONITOR_DIR/cc-auto-update-apply.sh" \
            "$_test_dir/_clone_drift.sh" 2>/dev/null | grep -v '^\S*:[0-9]*:#' || true)
assert_eq "no consumer retains a private lookup of the old key" "$leaks" ""

# ===========================================================================
echo
echo "== M9: the remedy does not contain a fresh instance of its own rule =="
# ===========================================================================
# #763's rule is "do not let a missing record silently become a default".
# A resolver chain is exactly where a new silent default gets written, and
# the specific way to write one here is `load.sh <key> <default>` — which
# makes the next rung unreachable. Assert the resolver never does it.

bad=$(grep -nE '"\$loader"[[:space:]]+"?\$?\{?[A-Za-z_.]+\}?"?[[:space:]]+[^ )|;&]' \
          "$RESOLVER" | grep -v '2>/dev/null); rc=\$?' || true)
assert_eq "the resolver never passes load.sh a default (that is the trap it fixes)" \
    "$bad" ""
assert_contains "…and it reads the exit code instead" \
    "$(cat "$RESOLVER")" "rc 2 → key ABSENT"

# The dated end of the transition must exist as DATA, not prose, so the
# note, the docs and the example config cannot drift apart.
DROP=$(
    source "$RESOLVER"
    printf '%s' "$NEXUS_INTEGRATION_BRANCH_OLD_KEY_DROP_DATE"
)
assert_eq "the drop date is a single definition" "$DROP" "2026-11-07"

# The contract must be TRUE, not merely written. Both variables must exist the
# moment the file is sourced — a `set -u` caller reading them before a resolve
# would otherwise abort, which is how the `$( )`-discards-the-assignment bug
# surfaced in `_config.sh` in the first place.
setu=$(
    set -u
    source "$RESOLVER"
    printf 'value=[%s] source=[%s]' \
        "$NEXUS_INTEGRATION_BRANCH_VALUE" "$NEXUS_INTEGRATION_BRANCH_SOURCE"
)
assert_eq "the exported variables are defined at load time (set -u safe)" \
    "$setu" "value=[] source=[]"

# …and the no-subshell call path actually populates them.
direct=$(
    unset MONITOR_INTEGRATION_BRANCH MONITOR_CLONE_DRIFT_BRANCH NEXUS_CONFIG
    export NEXUS_ROOT="$(make_root m9direct "clone_drift:" "  branch: release")"
    export NEXUS_INTEGRATION_BRANCH_QUIET=1
    source "$RESOLVER"
    _nexus_resolve_integration_branch          # NOT `$( )` — that is the point
    printf '%s/%s' "$NEXUS_INTEGRATION_BRANCH_VALUE" "$NEXUS_INTEGRATION_BRANCH_SOURCE"
)
assert_eq "a direct (non-subshell) resolve populates value AND source" \
    "$direct" "release/config-clone-drift-deprecated"

ROOT=$(make_root m9 "clone_drift:" "  branch: release")
R=$(resolve "$ROOT")
assert_contains "the deprecation note carries the drop DATE, not 'later'" \
    "$(f_notes "$R")" "$DROP"

for doc in "$REPO_ROOT/config/nexus.example.yml" "$MONITOR_DIR/README.md"; do
    assert_contains "$(basename "$doc") states the same drop date" \
        "$(cat "$doc")" "$DROP"
done

th_summary_and_exit
