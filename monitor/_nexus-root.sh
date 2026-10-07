#!/usr/bin/env bash
# _nexus-root.sh — the ONE resolver for "which nexus root is the PRIMARY".
#
# Sourceable helper. Defines `nexus_primary_root`, extracted verbatim from
# `monitor/ng` (your-org/nexus-code#577) so that every consumer answers the
# question the same way.
#
# WHY A SHARED FILE RATHER THAN A SECOND COPY (your-org/nexus-code#1077).
# `ng` resolved the primary correctly and then handed the asset step to
# `upload-asset.sh`, which rooted itself at its OWN script location and never
# read $NEXUS_ROOT at all. Two resolvers disagreeing is not a style problem: run
# from a secondary clone, the disagreement pointed the asset tree at
# `<clone>/assets`, and a half-created clone there made every later
# `git -C <clone>/assets` walk UP into the enclosing checkout — which was then
# `checkout main`, `reset --hard origin/main` and committed to, converting a
# nexus-code working tree into the asset repo and destroying 52 staged paths'
# worth of a worker's unpushed work. The script exited 0 and printed a URL.
#
# So: one function, one file, sourced by everything that needs it.

# nexus_primary_root <candidate> — print the PRIMARY nexus root for a candidate
# root, de-nesting a secondary clone out of any `<primary>/work/` it sits under.
#
# A secondary clone (`<primary>/work/<project>-<task>/`, the prescribed shape
# for watcher-touching work) is itself a full nexus tree: it has a `monitor/`,
# and often a `reports/`. So a bare $NEXUS_ROOT or a cwd walk-up can land on a
# clone's OWN state directories, where reports are invisible to the corpus
# consumers and assets are invisible to everything.
#
# The correction is STRUCTURAL and needs no configuration: if the candidate is
# nested under some ancestor's `work/`, and that ancestor is itself a plausible
# nexus root, the ancestor is the primary. Deliberately NOT config `nexus.root`:
# with NEXUS_ROOT unset, `config/load.sh` resolves relative to its own script
# dir, so from a clone with no `config/nexus.yml` it returns the
# `nexus.example.yml` placeholder `/path/to/nexus` — an oracle that answers with
# a placeholder exactly when the env is missing is no oracle at all.
#
# Returns 1 (and prints nothing) when the candidate is empty or not a directory.
#
# THE TEST FENCE (your-org/nexus-code#1680). The de-nesting above is right for a
# WORKER and wrong for a HERMETIC tree: a fixture nexus built under `mktemp -d`,
# or a mutation-gate copy, is also "a nexus tree nested under a nexus's work/"
# whenever the scratch dir happens to sit there — and it then resolved to the
# operator's PRIMARY. Measured: 321 fixture rows (res-win, stamp-win,
# other-name) in the primary's action log, the latest from a mutation-gate
# workdir under work/rmsk-band; and mutation baselines red because the copied
# tree took the primary's identity. So a test harness (run-tests.sh,
# mutation-gate.sh, _test_helpers.sh) exports NEXUS_TEST_FENCE=<its scratch
# root>, and under a fence an ancestor OUTSIDE the fence is never a primary:
# de-nesting inside the fence (a fixture primary + fixture clone, which the
# #577 suites build) is unchanged, and a tree nested under a real nexus
# resolves to itself — what CI, whose checkout is nested in nothing, sees.
# A fence that does not resolve admits NOTHING (fail-closed: no de-nesting).
nexus_fence_admits() {   # <canonical-dir> -> rc 0 when no fence, or inside it
    [[ -n "${NEXUS_TEST_FENCE:-}" ]] || return 0
    local f
    f=$(cd "$NEXUS_TEST_FENCE" 2>/dev/null && pwd -P) || return 1
    [[ -n "$f" ]] || return 1
    [[ "$1" == "$f" || "$1" == "$f"/* ]]
}

nexus_primary_root() {
    local cand="${1:-}"
    [[ -n "$cand" && -d "$cand" ]] || return 1
    cand=$(cd "$cand" 2>/dev/null && pwd -P) || return 1
    local up="$cand"
    while [[ "$up" == */work/* ]]; do
        up="${up%/work/*}"
        [[ -n "$up" ]] || break
        # Every further ancestor is a prefix of this one, so none can be inside
        # a fence this one is outside of: stop, and answer the candidate itself.
        nexus_fence_admits "$up" || break
        if [[ -d "$up/monitor" && -x "$up/monitor/ng" && -d "$up/config" \
              && "$up" != "$cand" ]]; then
            printf '%s' "$up"
            return 0
        fi
    done
    printf '%s' "$cand"
}

# ---------------------------------------------------------------------------
# WHICH NEXUS'S CONFIG — the ONE-TREE RULE (your-org/nexus-code#1650, #1651).
#
# `ng`, `upload-asset.sh` and `mint-token.sh` each used to answer "whose
# github.repo / asset repo / bot credentials?" their own way: ng from its own
# de-nested tree, the other two from the RAW $NEXUS_ROOT first. So with
# NEXUS_ROOT aimed at a foreign nexus, `ng` refused a write while `ng upload`
# wrote to the foreign root's asset repo at rc 0. One function now answers it.
#
# The nexus a tool acts for is the de-nested root of the TOOL'S OWN tree. When
# $NEXUS_ROOT names a DIFFERENT root:
#   * own tree has NO OPINION (no config/nexus.yml, or its github.repo is the
#     nexus.example.yml placeholder) -> $NEXUS_ROOT's root. This is the
#     config-less checkout outside work/, run with NEXUS_ROOT=<primary>: it
#     acts for the primary, as it always did (#1651 skeptic item 2).
#   * own tree HAS a config/nexus.yml that cannot be READ (config/load.sh
#     fails on it: a YAML parse error, no python3/pyyaml, no loader) ->
#     UNREADABLE, rc 2. A BROKEN config is not an ABSENT one: collapsing the
#     two let a tree with a malformed nexus.yml silently act for the nexus
#     $NEXUS_ROOT names (your-org/nexus-code#1652 item 3).
#   * both trees name the SAME identity (repo + asset repo) -> own root.
#   * otherwise -> CONFLICT: neither answer is safe to guess.
# $NEXUS_CONFIG is an explicit file and is the CALLER'S business; this function
# does not read it.

# nexus_tree_identity <root> — "<github.repo> <asset repo>" from <root>'s own
# config/nexus.yml. rc 1 and nothing when the tree has NO OPINION: no
# nexus.yml, a nexus.yml that names no github.repo (load.sh's documented rc 2,
# "key not present"), an EMPTY github.repo, or the example placeholder.
# rc 2 and nothing when the tree HAS a nexus.yml that cannot be READ:
# config/load.sh is missing, or fails with anything but "key not present" — a
# YAML parse error (an uncaught traceback, rc 1), no python3/pyyaml (rc 3).
# Callers must not fold rc 2 into rc 1 (CLAUDE.md "FALLBACK-COLLAPSE";
# your-org/nexus-code#1652 item 3).
# BOUNDARY, stated: "key not present" stays NO OPINION, as it was — a parsed
# nexus.yml whose github.repo is misspelt or missing still defers to
# NEXUS_ROOT. Refusing it too is a policy choice left open on #1652.
nexus_tree_identity() {
    local root="${1:-}" f="" repo="" ph="" asset="" lrc=0
    f="$root/config/nexus.yml"
    [[ -n "$root" && -f "$f" ]] || return 1
    [[ -x "$root/config/load.sh" ]] || return 2
    repo=$(NEXUS_CONFIG="$f" NEXUS_ROOT="$root" "$root/config/load.sh" github.repo 2>/dev/null) || lrc=$?
    (( lrc == 0 )) || { (( lrc == 2 )) && return 1; return 2; }
    [[ -n "$repo" ]] || return 1
    if [[ -f "$root/config/nexus.example.yml" ]]; then
        ph=$(NEXUS_CONFIG="$root/config/nexus.example.yml" NEXUS_ROOT="$root" \
             "$root/config/load.sh" github.repo 2>/dev/null) || ph=""
        [[ "$repo" == "$ph" ]] && return 1
    fi
    asset=$(NEXUS_CONFIG="$f" NEXUS_ROOT="$root" "$root/config/load.sh" github.asset_repo "$repo" 2>/dev/null) \
        || asset="$repo"
    printf '%s %s' "$repo" "${asset:-$repo}"
}

# nexus_config_root <own-candidate> — print the root whose config this tool
# must read. rc 0: the root. rc 1: the own candidate does not resolve.
# rc 2: UNREADABLE — the tool's own tree has a config/nexus.yml that cannot be
# read while $NEXUS_ROOT names another root; stdout carries a one-line
# description, and the caller MUST refuse (never fall back to $NEXUS_ROOT: that
# is the collapse this rc exists to prevent).
# rc 3: CONFLICT — stdout carries a one-line description naming both sides,
# and the caller MUST refuse any write that would use either side's identity.
nexus_config_root() {
    # Initialised: every caller runs under `set -u`, where a declared-but-unset
    # local ABORTS the subshell with rc 1 — an rc no caller may read as an answer.
    local own="" env="" own_id="" env_id="" irc=0 erc=0
    own=$(nexus_primary_root "${1:-}") || return 1
    if [[ -z "${NEXUS_ROOT:-}" ]]; then printf '%s' "$own"; return 0; fi
    env=$(nexus_primary_root "$NEXUS_ROOT") || env=""
    if [[ -z "$env" || "$env" -ef "$own" ]]; then printf '%s' "$own"; return 0; fi
    own_id=$(nexus_tree_identity "$own") || irc=$?
    if (( irc == 2 )); then                   # own config BROKEN, not absent
        printf '%s has a config/nexus.yml that cannot be read (config/load.sh failed on it), so this tool cannot tell whether it acts for that tree or for NEXUS_ROOT=%s' \
            "$own" "$env"
        return 2
    elif (( irc != 0 )); then
        printf '%s' "$env"; return 0          # own tree has NO OPINION
    fi
    # Kept apart for the MESSAGE only: an unreadable env config is no identity,
    # so it conflicts with own's and the caller refuses either way.
    env_id=$(nexus_tree_identity "$env") || { erc=$?; env_id=""; }
    if [[ "$env_id" == "$own_id" ]]; then
        printf '%s' "$own"; return 0          # same identity: no conflict
    fi
    local env_disp="no config of its own"
    (( erc == 2 )) && env_disp="a config/nexus.yml that cannot be read"
    [[ -n "$env_id" ]] && env_disp="github.repo=${env_id% *} asset repo=${env_id#* }"
    printf 'NEXUS_ROOT names %s (%s), but this tool belongs to %s (github.repo=%s asset repo=%s)' \
        "$env" "$env_disp" "$own" "${own_id% *}" "${own_id#* }"
    return 3
}
