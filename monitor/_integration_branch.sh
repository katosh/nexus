#!/usr/bin/env bash
# _integration_branch.sh — THE single resolver for "the branch merged
# fixes land on" (your-org/nexus-code#763).
#
# ONE PROPERTY, ONE CLAIMANT, ENFORCED BY CONSTRUCTION. The repo has two
# consumers of this fact:
#
#   * monitor/watcher/_clone_drift.sh   — the #620 primary-clone
#                                         deployment-drift detector;
#   * monitor/cc-auto-update-apply.sh   — the #754 cc-auto-update
#                                         deployment gate.
#
# Both now call `nexus_integration_branch`. Before this file they each
# reached for `monitor.clone_drift.branch` on their own, which held the
# "exactly one claimant" property BY CONVENTION — a comment in
# `_gate_integration_branch` asking the next author not to mint a second
# key. Conventions are not enforcement; a shared function is. If a third
# consumer appears it calls this, or it is wrong in a way review can see.
#
# ---------------------------------------------------------------------
# THE MIGRATION IS THE HAZARD, NOT THE RENAME
# ---------------------------------------------------------------------
#
# `config/nexus.yml` is per-operator and NOT tracked in this repo. So a
# bare rename of `monitor.clone_drift.branch` → `monitor.integration_branch`
# lands on every operator clone as a SILENT DEFAULT FALLBACK: the new key
# is absent, the default applies, and an operator who deliberately set
# `release` (or `main`, or a fork's flow) silently gets `dev`. Nothing
# errors. The wrong branch then feeds the deployment gate — the surface
# #754 had just finished making trustworthy.
#
# That is this repo's dominant defect class (silence standing in for a
# real answer) arriving through a config default. The transition is
# therefore READ-BOTH / PREFER-NEW / NOTE-ON-OLD, with a dated end.
#
# Resolution order — first hit wins:
#
#   1. $MONITOR_INTEGRATION_BRANCH   env, canonical
#   2. $MONITOR_CLONE_DRIFT_BRANCH   env, DEPRECATED but still honoured.
#                                    _config.sh sets it, every existing
#                                    test fixture exports it, and dropping
#                                    it would break the watcher's own
#                                    plumbing for no gain.
#   3. config monitor.integration_branch    canonical key
#   4. config monitor.clone_drift.branch    DEPRECATED key → one-line note
#   5. `dev`                                last-resort default
#
# ---------------------------------------------------------------------
# THE TRAP INSIDE THE REMEDY
# ---------------------------------------------------------------------
#
# Step 3 must distinguish "the new key is ABSENT" from "the new key says
# dev". `config/load.sh <key> dev` cannot: it prints `dev` for both, so a
# resolver written that way NEVER REACHES STEP 4 and reproduces, inside
# the fix, the exact silent-default bug #763 was filed about. So step 3
# calls `load.sh` with NO default and reads the exit code:
#
#     rc 0 → key present   (value on stdout)
#     rc 2 → key ABSENT    — the ONLY rc that licenses falling through
#     rc * → COULD NOT LOOK (rc 1 no config file, rc 3 no python3/pyyaml)
#
# `could not look` is NOT `absent`. Collapsing them would answer `dev`
# with the same confidence for "you have no config file" as for "your
# config says dev" — #740's thesis. It gets its own loud note and does
# NOT silently walk the rest of the chain as though both keys were
# missing.
#
# ---------------------------------------------------------------------
# WHEN THE OLD KEY STOPS BEING READ
# ---------------------------------------------------------------------
#
# Step 4 is removed on **2026-11-07** (three months after 2026-08-07,
# when this shipped). The date is in the operator-facing note itself,
# not only in a changelog nobody re-reads. `test-config-integration-branch.sh`
# pins the date so it cannot drift between the note, the docs and the
# example config.
#
# ---------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------
#
#   nexus_integration_branch
#     stdout : the branch name, always non-empty
#     rc     : always 0 (there is no failure mode that should stop a
#              caller — a missing config yields `dev` plus a loud note)
#
#   nexus_integration_branch_tsv
#     stdout : "<branch>\t<source>"
#
#   Both also set $NEXUS_INTEGRATION_BRANCH_VALUE and
#   $NEXUS_INTEGRATION_BRANCH_SOURCE in the CALLER's shell — but only when
#   called WITHOUT a command substitution. `b=$(nexus_integration_branch)`
#   runs in a subshell, so the assignments are discarded; every real caller
#   uses that form, which is why the provenance is also available through
#   STDOUT via the `_tsv` variant rather than as a documented caveat nobody
#   reads. Both variables are initialised at load time so a `set -u` caller
#   reading them can never trip on "unbound variable".
#
#   $NEXUS_INTEGRATION_BRANCH_SOURCE is one of:
#     env-integration | env-clone-drift-deprecated | config-integration |
#     config-clone-drift-deprecated | default | default-unreadable-config
#
# Notes go to STDERR (stdout carries the branch and nothing else) and
# fire at most ONCE PER PROCESS per distinct note, so an hourly tick
# cannot turn a deprecation into log spam. Set
# NEXUS_INTEGRATION_BRANCH_QUIET=1 to silence them entirely.
#
# Pure functions, no top-level side effects beyond the source guard:
# safe to source from a script, a test, or a subshell.

[[ -n "${_INTEGRATION_BRANCH_SH_LOADED:-}" ]] && return 0
_INTEGRATION_BRANCH_SH_LOADED=1

# The date step 4 is removed. Single definition; the docs and the test
# both read it from here rather than restating it.
NEXUS_INTEGRATION_BRANCH_OLD_KEY_DROP_DATE=2026-11-07

# Initialised at load time so a `set -u` caller that reads either one before
# (or without) a resolve gets an empty string rather than an unbound-variable
# abort. Found by smoke-testing `_config.sh`: the resolver set SOURCE inside
# the function, every caller invoked it as `$(...)`, and the assignment died
# with the subshell — a contract the header asserted and the code did not keep.
NEXUS_INTEGRATION_BRANCH_VALUE=""
NEXUS_INTEGRATION_BRANCH_SOURCE=""

_INTEGRATION_BRANCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Which notes have already fired in this process.
_IB_NOTED=""

# _ib_note <tag> <message…> — emit once per tag per process.
_ib_note() {
    local tag="$1"; shift
    [[ "${NEXUS_INTEGRATION_BRANCH_QUIET:-0}" == "1" ]] && return 0
    case "$_IB_NOTED" in *"|$tag|"*) return 0 ;; esac
    _IB_NOTED="${_IB_NOTED}|$tag|"
    printf 'integration-branch: %s\n' "$*" >&2
}

# _ib_loader — path to config/load.sh, or empty.
#
# $NEXUS_ROOT first, matching every other config consumer in the repo
# (and _gate_integration_branch's prior behaviour); script-relative as
# the fallback so a resolver sourced with NEXUS_ROOT unset still reads
# its own clone's config rather than nothing at all.
_ib_loader() {
    local c
    for c in "${NEXUS_ROOT:-}/config/load.sh" \
             "$_INTEGRATION_BRANCH_DIR/../config/load.sh"; do
        [[ "$c" == "/config/load.sh" ]] && continue   # NEXUS_ROOT unset
        [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# _ib_config_get <dotted.key>
#   rc 0 → present and non-empty; value on stdout
#   rc 2 → absent, or present-but-empty (an empty branch is not a value)
#   rc 3 → COULD NOT LOOK: no loader, no config file, or no python3/pyyaml
#
# NOTE the deliberate absence of a default argument. See "THE TRAP
# INSIDE THE REMEDY" above — passing one is what makes the fall-through
# unreachable.
_ib_config_get() {
    local key="$1" loader out rc
    loader=$(_ib_loader) || return 3
    out=$("$loader" "$key" 2>/dev/null); rc=$?
    case "$rc" in
        0)
            if [[ -z "$out" ]]; then
                _ib_note "empty-$key" \
                    "config key '$key' is present but EMPTY — treating as unset."
                return 2
            fi
            printf '%s' "$out"; return 0 ;;
        2)  return 2 ;;
        *)  return 3 ;;
    esac
}

# _nexus_resolve_integration_branch — the resolution itself. Sets
# NEXUS_INTEGRATION_BRANCH_VALUE + _SOURCE in the caller's shell and prints
# NOTHING, so the two public wrappers below can each present it however their
# caller consumes it.
_nexus_resolve_integration_branch() {
    local v rc

    if [[ -n "${MONITOR_INTEGRATION_BRANCH:-}" ]]; then
        NEXUS_INTEGRATION_BRANCH_SOURCE=env-integration
        NEXUS_INTEGRATION_BRANCH_VALUE="$MONITOR_INTEGRATION_BRANCH"; return 0
    fi

    if [[ -n "${MONITOR_CLONE_DRIFT_BRANCH:-}" ]]; then
        NEXUS_INTEGRATION_BRANCH_SOURCE=env-clone-drift-deprecated
        _ib_note env-old \
            "\$MONITOR_CLONE_DRIFT_BRANCH is DEPRECATED (it names one consumer of a repo-wide property); use \$MONITOR_INTEGRATION_BRANCH. Still honoured until ${NEXUS_INTEGRATION_BRANCH_OLD_KEY_DROP_DATE}."
        NEXUS_INTEGRATION_BRANCH_VALUE="$MONITOR_CLONE_DRIFT_BRANCH"; return 0
    fi

    # --- config: canonical key -------------------------------------------
    local new_v="" new_present=0 unreadable=0
    v=$(_ib_config_get monitor.integration_branch); rc=$?
    case "$rc" in
        0) new_v="$v"; new_present=1 ;;
        3) unreadable=1 ;;
    esac

    # --- config: deprecated key ------------------------------------------
    # Read even when the new key answered, so a clone carrying BOTH with
    # DIFFERENT values is reported rather than silently resolved. Two
    # records of one property disagreeing is precisely the state #754's
    # comment refused to create, and it must not pass unremarked when an
    # operator creates it by hand mid-migration.
    local old_v="" old_present=0
    if (( ! unreadable )); then
        v=$(_ib_config_get monitor.clone_drift.branch); rc=$?
        case "$rc" in
            0) old_v="$v"; old_present=1 ;;
            3) unreadable=1 ;;
        esac
    fi

    if (( new_present )); then
        if (( old_present )) && [[ "$old_v" != "$new_v" ]]; then
            _ib_note conflict \
                "CONFLICT: monitor.integration_branch='${new_v}' but the deprecated monitor.clone_drift.branch='${old_v}'. Using '${new_v}'. Delete the old key — two records of one property WILL drift."
        elif (( old_present )); then
            _ib_note both \
                "both monitor.integration_branch and the deprecated monitor.clone_drift.branch are set (same value '${new_v}'); delete the old key."
        fi
        NEXUS_INTEGRATION_BRANCH_SOURCE=config-integration
        NEXUS_INTEGRATION_BRANCH_VALUE="$new_v"; return 0
    fi

    if (( old_present )); then
        _ib_note config-old \
            "config key 'monitor.clone_drift.branch' is DEPRECATED — rename it to 'monitor.integration_branch' in config/nexus.yml. Your value ('${old_v}') is being honoured, and will keep being honoured until ${NEXUS_INTEGRATION_BRANCH_OLD_KEY_DROP_DATE}; after that date an unrenamed key silently becomes 'dev'."
        NEXUS_INTEGRATION_BRANCH_SOURCE=config-clone-drift-deprecated
        NEXUS_INTEGRATION_BRANCH_VALUE="$old_v"; return 0
    fi

    if (( unreadable )); then
        # "I could not look" must not read as "you configured dev".
        _ib_note unreadable \
            "could NOT read the config (no config/load.sh, no config file, or python3/pyyaml missing) — falling back to 'dev'. This is a GUESS, not your configured value."
        NEXUS_INTEGRATION_BRANCH_SOURCE=default-unreadable-config
        NEXUS_INTEGRATION_BRANCH_VALUE=dev; return 0
    fi

    NEXUS_INTEGRATION_BRANCH_SOURCE=default
    NEXUS_INTEGRATION_BRANCH_VALUE=dev; return 0
}

# nexus_integration_branch — the branch, on stdout. See the header contract.
nexus_integration_branch() {
    _nexus_resolve_integration_branch
    printf '%s' "$NEXUS_INTEGRATION_BRANCH_VALUE"
}

# nexus_integration_branch_tsv — "<branch>\t<source>" on stdout, for the
# caller that uses `$( )` and therefore cannot see the shell variables.
nexus_integration_branch_tsv() {
    _nexus_resolve_integration_branch
    printf '%s\t%s' "$NEXUS_INTEGRATION_BRANCH_VALUE" \
                     "$NEXUS_INTEGRATION_BRANCH_SOURCE"
}
