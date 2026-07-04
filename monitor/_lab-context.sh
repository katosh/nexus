#!/usr/bin/env bash
# monitor/_lab-context.sh — deterministic env probes for OPTIONAL,
# site-specific bootstrap addons (an HPC skills bundle, labsh).
#
# These detect a site-specific environment. On a generic host with no
# adopter configuration they all read "not present", and the install-
# prompt's "Lab-specific addons" phase becomes a no-op. An adopter who
# runs on an HPC cluster wires the probes up via the env hooks below.
#
# Sourced by:
#   * monitor/bootstrap-install.sh — propagates signals into the
#     install-prompt context block.
#   * monitor/install-prompt.md "Phase X — Lab-specific addons" bash
#     directives — re-runs the same probes to drive the conditional
#     install offer.
#
# Contract for each probe:
#   * Exits 0 always (idempotent observation, not a gate).
#   * Emits one line `key=value` to stdout, no extras.
#   * No network calls. Org-membership probing (`gh api orgs/.../members
#     /<bot>`) is the install-prompt agent's job; the bash layer stays
#     offline so bootstrap can run with broken network.
#
# Adopter / test env hooks (all unset by default → every probe reads
# "no", so a generic host offers no addons):
#   _NEXUS_HPC_MOUNT          absolute fast-storage mount to probe for
#                             (your cluster's shared /scratch, /data, …).
#                             SET ME to enable HPC detection.
#   _NEXUS_HPC_HOST_PREFIXES  '|'-separated hostname prefixes that mark
#                             an HPC login/compute node (e.g. 'login|gpu').
#                             SET ME alongside _NEXUS_HPC_MOUNT.
#   _NEXUS_HOSTNAME           override `hostname -s` output (tests).
#   _NEXUS_HPC_SKILLS_DIR     dirname of your skills bundle under
#                             ~/.claude/skills (default: hpc-skills).

# --- nexus_detect_hpc ---------------------------------------------------
# Both signals must hold:
#   1. The configured HPC mount (_NEXUS_HPC_MOUNT) exists and is reachable.
#   2. `hostname -s` matches one of _NEXUS_HPC_HOST_PREFIXES.
# Path alone isn't enough (a laptop could mount the share via SSHFS);
# hostname alone isn't enough (someone could rename a VM). With neither
# hook set (a generic host), this reads hpc=0.
nexus_detect_hpc() {
    local mount="${_NEXUS_HPC_MOUNT:-}"
    local prefixes="${_NEXUS_HPC_HOST_PREFIXES:-}"
    local host="${_NEXUS_HOSTNAME-}"
    if [[ -z "$host" && -z "${_NEXUS_HOSTNAME+x}" ]]; then
        host=$(hostname -s 2>/dev/null || true)
    fi
    if [[ -n "$mount" && -n "$prefixes" && -d "$mount" && "$host" =~ ^(${prefixes}) ]]; then
        echo "hpc=1"
    else
        echo "hpc=0"
    fi
}

# --- nexus_detect_hpc_skills_installed ----------------------------------
# Either a symlink (the sandbox-correct pattern) or a direct directory
# at ~/.claude/skills/<bundle> counts as installed. `-L` matches even
# dangling symlinks — by convention, operator-placed links are the
# operator's to clean up. <bundle> defaults to `hpc-skills`; override
# with _NEXUS_HPC_SKILLS_DIR.
nexus_detect_hpc_skills_installed() {
    local bundle="${_NEXUS_HPC_SKILLS_DIR:-hpc-skills}"
    local entry="$HOME/.claude/skills/$bundle"
    if [[ -L "$entry" || -d "$entry" ]]; then
        echo "installed=1"
    else
        echo "installed=0"
    fi
}

# --- nexus_detect_labsh_installed ---------------------------------------
# Either a project-local clone under $SANDBOX_PROJECT_DIR/work/labsh
# or `labsh` on PATH counts as installed. Defensive against unset
# SANDBOX_PROJECT_DIR (the probe library may be sourced from contexts
# where the var's lifetime is fuzzy).
nexus_detect_labsh_installed() {
    local sandbox="${SANDBOX_PROJECT_DIR-}"
    if [[ -n "$sandbox" && -d "$sandbox/work/labsh" ]]; then
        echo "installed=1"
        return 0
    fi
    if command -v labsh >/dev/null 2>&1; then
        echo "installed=1"
        return 0
    fi
    echo "installed=0"
}
