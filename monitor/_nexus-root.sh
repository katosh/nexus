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
nexus_primary_root() {
    local cand="${1:-}"
    [[ -n "$cand" && -d "$cand" ]] || return 1
    cand=$(cd "$cand" 2>/dev/null && pwd -P) || return 1
    local up="$cand"
    while [[ "$up" == */work/* ]]; do
        up="${up%/work/*}"
        [[ -n "$up" ]] || break
        if [[ -d "$up/monitor" && -x "$up/monitor/ng" && -d "$up/config" \
              && "$up" != "$cand" ]]; then
            printf '%s' "$up"
            return 0
        fi
    done
    printf '%s' "$cand"
}
