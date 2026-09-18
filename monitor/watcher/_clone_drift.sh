#!/usr/bin/env bash
# Primary-clone deployment-drift detection (your-org/nexus-code#614).
#
# THE GAP THIS CLOSES. `_version_restart.sh` (#186) makes `git pull` the
# whole update story: it hashes each component's source set and restarts
# what changed. But it detects drift in the source set AFTER a pull —
# it cannot see that the pull NEVER HAPPENED. Between 2026-07-25 and
# 2026-07-30 the primary clone sat at `0894d72` while `dev` advanced 31
# commits and 8 merged PRs, and nothing anywhere reported it. Every one
# of those PRs was reviewed, CI'd, skeptic-validated and merged; the
# gap is that merging is treated as the terminal state, and for a repo
# that is simultaneously the source AND the running system it is not.
#
# A green merge is a PROXY for "the fix is in effect". The property is
# "the code the watcher and spawner actually execute contains the fix".
# This module measures at that boundary.
#
# DETECTION ONLY — THIS MODULE NEVER MUTATES THE CLONE. No pull, no
# merge, no checkout, and deliberately no `git fetch` either. Pulling
# mutates shared live state: the watcher sources `_*.sh` helpers once at
# startup and in-flight workers source them from disk, so a mid-flight
# swap makes functions in memory call functions on disk with mismatched
# arity — bash fails quietly and eligible comments stop surfacing with
# no log error. Deploying is a human-timed orchestrator action; this
# module only makes NOT deploying impossible to not notice.
#
# `git ls-remote` is the probe. It speaks to the remote and prints the
# tip WITHOUT writing a single ref or object, so it is safe to run
# against the live clone on a timer. (The originating issue asserted
# that plain `git fetch` "fails silently on an expired baked-in
# installation token", freezing remote-tracking refs. That was checked
# on this clone and is FALSE for it: `origin` is
# `git@github.com:…` — SSH, no token in the URL — and both `ls-remote`
# and `fetch --dry-run` return rc=0 with the current tip. The real trap
# is narrower and worse, because it survives a working fetch: reading
# `origin/dev` WITHOUT having fetched. When this module was written the
# primary's `origin/dev` pointed at `1315412`, so `git rev-list --count
# HEAD..origin/dev` answered **31** while the true distance to the
# remote tip `c906e49` was **59**. A stale remote-tracking ref does not
# error; it just answers a question about the past. So the tip is ALWAYS
# taken from the live probe, never from a local remote-tracking ref.)
#
# THE TRICHOTOMY IS THE POINT. Three verdicts, never two:
#
#   up-to-date   HEAD is at, or ahead of, the remote tip.
#   behind       HEAD is behind by a measured margin.
#   unknown      We could not establish the answer.
#
# `unknown` is a DISTINCT, LOUD outcome and must never collapse into
# `up-to-date`. That collapse is the entire failure mode this module
# exists to prevent: a detector that reports green when it cannot see is
# worse than no detector, because it converts an unmonitored condition
# into a monitored-and-believed-healthy one. Every early return below
# that cannot prove currency returns `unknown` with a reason.
#
# THRESHOLDS — either trips, because they catch different shapes:
#   commits  a burst of merges that has not deployed (default 5)
#   hours    a single commit that has sat undeployed a long time
#            (default 24), measured from the OLDEST undeployed commit,
#            not from HEAD — an old HEAD with no newer commits is
#            perfectly current and must not alarm.
#
# Verdict is surfaced by writing a `drift-clone` ask record into the
# version state dir, which `_version_emit_section` already renders and
# re-nag-guards. No new compose_report plumbing.
#
# Globals consumed (all overridable so tests can aim it at a fixture):
#   NEXUS_ROOT                    clone to judge
#   VERSION_STATE_DIR             where the ask record lands
#   MONITOR_CLONE_DRIFT_ENABLED   true|false (default true)
#   MONITOR_INTEGRATION_BRANCH    remote branch (default dev). Resolved
#                                 through the SHARED resolver in
#                                 monitor/_integration_branch.sh (#763),
#                                 which also honours the DEPRECATED
#                                 MONITOR_CLONE_DRIFT_BRANCH env var and
#                                 the deprecated `monitor.clone_drift.branch`
#                                 config key until 2026-11-07.
#   MONITOR_CLONE_DRIFT_COMMITS   commit threshold (default 5)
#   MONITOR_CLONE_DRIFT_HOURS     hour threshold (default 24)
#   _CLONE_DRIFT_GIT_BIN          git (test-injectable)
#   _CLONE_DRIFT_GH_BIN           gh  (test-injectable)
#   NEXUS_TEST_NOW                clock override (test-injectable)

[[ -n "${_CLONE_DRIFT_SOURCED:-}" ]] && return 0
_CLONE_DRIFT_SOURCED=1

# `nexus_integration_branch` — the ONE resolver for the branch merged
# fixes land on (your-org/nexus-code#763). Located SCRIPT-RELATIVE, not
# via $NEXUS_ROOT: this module is deliberately aimed at arbitrary clone
# fixtures by its test suite, and $NEXUS_ROOT there is a bare git repo
# with no `monitor/` at all.
# shellcheck source=../_integration_branch.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_integration_branch.sh"

# shellcheck source=../repo-root.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/repo-root.sh"

_clone_drift_git() { "${_CLONE_DRIFT_GIT_BIN:-git}" "$@"; }
_clone_drift_gh()  { "${_CLONE_DRIFT_GH_BIN:-gh}" "$@"; }

# Wall-clock bound for the two calls that touch the NETWORK
# (`git ls-remote`, `gh api compare`). This tick runs on the async
# scheduler slot, and the wedge guard (your-org/nexus-code#367) exists
# because one hung remote call froze the whole watcher scheduler: the
# heartbeat stops advancing, child task-forks pile up, and there is a
# multi-minute blind window until the supervisor force-restarts. A
# drift check is the least urgent thing here — it must never be the
# thing that wedges the loop. A timeout kill yields a non-zero exit,
# which the caller already turns into `unknown` (loud), so the bound
# degrades into the honest verdict rather than a false green.
#
# `timeout` cannot exec a bash function, so tests that shadow git/gh
# install a matching `timeout` shadow — keeping ONE production path.
_clone_drift_bounded() {
    local t="${MONITOR_CLONE_DRIFT_TIMEOUT_SECONDS:-30}"
    [[ "$t" =~ ^[0-9]+$ && "$t" -gt 0 ]] || t=30
    timeout -k 5 "$t" "$@"
}

_clone_drift_now() {
    if [[ -n "${NEXUS_TEST_NOW:-}" ]]; then printf '%s' "$NEXUS_TEST_NOW"; return 0; fi
    date +%s
}

_clone_drift_log() {
    if declare -F log >/dev/null 2>&1; then log "clone-drift: $*"; fi
}

# Resolve `owner/repo` from the clone's origin URL. Handles both SSH
# (`git@host:owner/repo.git`) and HTTPS (`https://host/owner/repo.git`).
# Empty + rc 1 when it cannot be determined — which the caller turns
# into `unknown`, never into `up-to-date`.
_clone_drift_slug() {
    local root="$1" url
    url=$(_clone_drift_git -C "$root" remote get-url origin 2>/dev/null) || return 1
    [[ -n "$url" ]] || return 1
    url="${url%.git}"
    case "$url" in
        *://*) url="${url#*://}"; url="${url#*@}"; url="${url#*/}" ;;
        *:*)   url="${url##*:}" ;;
        *)     return 1 ;;
    esac
    [[ "$url" == */* ]] || return 1
    printf '%s' "$url"
}

# _clone_drift_probe <root> <branch>
#
# The single decision function. stdout is ONE line, `key=value` pairs:
#
#   verdict=up-to-date head=<sha> tip=<sha>
#   verdict=behind head=<sha> tip=<sha> commits=<n|unknown> oldest_epoch=<e|unknown>
#   verdict=unknown reason=<slug> detail=<text>
#
# rc is always 0; the verdict is the payload.
_clone_drift_probe() {
    local root="$1" branch="$2"

    # THIS GUARD USED TO BE `#1080`'s SHAPE VERBATIM —
    #
    #   [[ ! -d "$root/.git" ]] && ! _clone_drift_git -C "$root" rev-parse --git-dir …
    #
    # — and both arms walk up (your-org/nexus-code#1196). `--git-dir` succeeds
    # for any path INSIDE a repository, so a `$root` that is not a repository
    # passed the guard and every measurement below was then taken against the
    # nearest ENCLOSING repository: `rev-parse HEAD` returns that repo's HEAD,
    # `ls-remote` its origin, and the verdict is a confident `up-to-date` or
    # `behind` about a clone that was never examined. In a nexus the enclosing
    # repository is the nexus itself, so the wrong answer is also a plausible
    # one. Latent rather than live today — both call sites pass a real clone
    # root — but this is the deployment gate, and a gate that can be answered
    # about the wrong repository is not a gate.
    #
    # `rr_has_own_history` is the READ-side question, so a LINKED WORKTREE
    # still probes correctly: its HEAD and branch are genuinely its own. 131
    # of the 881 directories under this nexus's `work/` are linked worktrees,
    # so the stricter write-side predicate would refuse a large, legitimate
    # population.
    local _cd_rc
    rr_has_own_history "$root"; _cd_rc=$?
    if [[ $_cd_rc -eq 1 ]]; then
        printf 'verdict=unknown reason=not_a_git_repo detail=%s\n' "$root"; return 0
    elif [[ $_cd_rc -ne 0 ]]; then
        # UNDETERMINED IS NOT "NOT A REPO". Collapsing it would report a
        # repository we merely could not inspect as one that does not exist,
        # and the operator would read a real clone as absent.
        printf 'verdict=unknown reason=repo_root_undetermined detail=%s\n' "$root"; return 0
    fi

    local head
    head=$(_clone_drift_git -C "$root" rev-parse HEAD 2>/dev/null)
    if [[ ! "$head" =~ ^[0-9a-f]{7,40}$ ]]; then
        printf 'verdict=unknown reason=no_local_head detail=rev-parse_HEAD_failed\n'; return 0
    fi

    # Live tip. `ls-remote` writes nothing; its EXIT STATUS is checked
    # and a non-SHA answer is treated as failure — the issue's "verify
    # the fetch's exit status" requirement, applied to a probe that has
    # no side effects to verify away.
    local lsr rc tip=""
    lsr=$(_clone_drift_bounded "${_CLONE_DRIFT_GIT_BIN:-git}" -C "$root" \
              ls-remote origin "refs/heads/$branch" 2>/dev/null); rc=$?
    if (( rc == 0 )) && [[ -n "$lsr" ]]; then
        tip="${lsr%%[[:space:]]*}"
    fi
    if [[ ! "$tip" =~ ^[0-9a-f]{7,40}$ ]]; then
        printf 'verdict=unknown reason=remote_tip_unresolved detail=ls-remote_rc=%s_branch=%s\n' \
            "$rc" "$branch"
        return 0
    fi

    if [[ "$head" == "$tip" ]]; then
        printf 'verdict=up-to-date head=%s tip=%s\n' "$head" "$tip"; return 0
    fi

    # How far behind? Prefer a purely local answer when the remote tip
    # object already exists here (some other command fetched it), since
    # that needs no network and no token. `--is-ancestor` is the
    # ahead/behind discriminator: HEAD ahead of tip is NOT drift.
    if _clone_drift_git -C "$root" cat-file -e "${tip}^{commit}" 2>/dev/null; then
        if _clone_drift_git -C "$root" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then
            printf 'verdict=up-to-date head=%s tip=%s\n' "$head" "$tip"; return 0
        fi
        local n oldest
        n=$(_clone_drift_git -C "$root" rev-list --count "${head}..${tip}" 2>/dev/null)
        if [[ "$n" =~ ^[0-9]+$ ]]; then
            if (( n == 0 )); then
                printf 'verdict=up-to-date head=%s tip=%s\n' "$head" "$tip"; return 0
            fi
            oldest=$(_clone_drift_git -C "$root" rev-list --reverse "${head}..${tip}" 2>/dev/null | head -n1)
            local oep="unknown"
            [[ -n "$oldest" ]] && oep=$(_clone_drift_git -C "$root" show -s --format=%ct "$oldest" 2>/dev/null)
            [[ "$oep" =~ ^[0-9]+$ ]] || oep="unknown"
            printf 'verdict=behind head=%s tip=%s commits=%s oldest_epoch=%s\n' \
                "$head" "$tip" "$n" "$oep"
            return 0
        fi
    fi

    # Remote tip not present locally — ask the API to compare, which
    # touches nothing in the clone. `compare/<base>...<branch>` reports
    # `ahead_by` = commits the branch has that base does not = exactly
    # how far base is behind.
    local slug
    if ! slug=$(_clone_drift_slug "$root"); then
        printf 'verdict=unknown reason=no_origin_slug detail=could_not_parse_origin_url\n'; return 0
    fi
    local cmp
    cmp=$(_clone_drift_bounded "${_CLONE_DRIFT_GH_BIN:-gh}" api \
              "repos/${slug}/compare/${head}...${branch}" 2>/dev/null); rc=$?
    if (( rc != 0 )) || [[ -z "$cmp" ]]; then
        # We KNOW head != tip, so this is drift of unmeasured size. Say
        # `behind` with an unknown margin rather than `unknown` — the
        # inequality is an observation, and downgrading it to "cannot
        # tell" would understate a condition we have already proven.
        printf 'verdict=behind head=%s tip=%s commits=unknown oldest_epoch=unknown\n' "$head" "$tip"
        return 0
    fi
    local ahead behind_by status oldest_iso oep
    ahead=$(printf '%s' "$cmp" | jq -r '.ahead_by // empty' 2>/dev/null)
    behind_by=$(printf '%s' "$cmp" | jq -r '.behind_by // empty' 2>/dev/null)
    status=$(printf '%s' "$cmp" | jq -r '.status // empty' 2>/dev/null)
    # `identical` or `behind` (branch behind base) both mean HEAD is
    # current or ahead — not drift.
    if [[ "$status" == "identical" || "$status" == "behind" ]] \
       || [[ "$ahead" == "0" ]]; then
        printf 'verdict=up-to-date head=%s tip=%s\n' "$head" "$tip"; return 0
    fi
    [[ "$ahead" =~ ^[0-9]+$ ]] || ahead="unknown"
    oldest_iso=$(printf '%s' "$cmp" | jq -r '.commits[0].commit.committer.date // empty' 2>/dev/null)
    oep="unknown"
    if [[ -n "$oldest_iso" ]]; then
        oep=$(date -d "$oldest_iso" +%s 2>/dev/null || true)
        [[ "$oep" =~ ^[0-9]+$ ]] || oep="unknown"
    fi
    printf 'verdict=behind head=%s tip=%s commits=%s oldest_epoch=%s diverged=%s\n' \
        "$head" "$tip" "$ahead" "$oep" "${behind_by:-0}"
    return 0
}

_clone_drift_field() {
    local line="$1" key="$2"
    printf '%s' "$line" | tr ' ' '\n' | awk -F= -v k="$key" '$1==k{print $2; exit}'
}

# _clone_drift_tick — scheduler entry point. Evaluates the primary
# clone and, past either threshold (or on `unknown`), persists a
# `drift-clone` ask record for `_version_emit_section` to surface.
_clone_drift_tick() {
    [[ "${MONITOR_CLONE_DRIFT_ENABLED:-true}" == "true" ]] || return 0
    local state_dir="${VERSION_STATE_DIR:-}"
    [[ -n "$state_dir" ]] || return 0
    local root="${NEXUS_ROOT:-}"
    [[ -n "$root" ]] || return 0
    # #763 — the SHARED resolver, not a local `${…:-dev}`. That default
    # was the module's own second claimant on a repo-wide property: it
    # answered `dev` whenever `_config.sh` had not been sourced, which is
    # every non-watcher caller. One resolver, one answer.
    local branch; branch=$(nexus_integration_branch)
    local max_commits="${MONITOR_CLONE_DRIFT_COMMITS:-5}"
    [[ "$max_commits" =~ ^[0-9]+$ ]] || max_commits=5
    local max_hours="${MONITOR_CLONE_DRIFT_HOURS:-24}"
    [[ "$max_hours" =~ ^[0-9]+$ ]] || max_hours=24

    local line verdict
    line=$(_clone_drift_probe "$root" "$branch")
    verdict=$(_clone_drift_field "$line" verdict)
    local now; now=$(_clone_drift_now)

    case "$verdict" in
        up-to-date)
            # Clear any standing record: the condition resolved.
            rm -f "$state_dir/drift-clone" "$state_dir/drift-clone-surfaced" 2>/dev/null || true
            _clone_drift_log "up to date with origin/$branch"
            return 0
            ;;
        unknown)
            local reason detail
            reason=$(_clone_drift_field "$line" reason)
            detail=$(_clone_drift_field "$line" detail)
            _clone_drift_log "COULD NOT DETERMINE drift (reason=$reason detail=$detail)"
            # Keyed on the reason so a persistent inability to see
            # announces once, not every tick — but a NEW reason renags.
            _version_write_drift_record "$state_dir" clone "" "undetermined-${reason}" \
                "could-not-determine|${reason}|${detail}|${branch}"
            return 0
            ;;
    esac

    local commits oldest tip head
    commits=$(_clone_drift_field "$line" commits)
    oldest=$(_clone_drift_field "$line" oldest_epoch)
    tip=$(_clone_drift_field "$line" tip)
    head=$(_clone_drift_field "$line" head)

    local hours=0
    if [[ "$oldest" =~ ^[0-9]+$ ]] && (( now > oldest )); then
        hours=$(( (now - oldest) / 3600 ))
    fi

    # Either threshold trips. An UNMEASURABLE margin (`commits=unknown`)
    # also trips: we proved HEAD != tip, and refusing to report that
    # because we could not count it would be the same silence again.
    local trip=0 why=""
    if [[ "$commits" == "unknown" ]]; then
        trip=1; why="HEAD differs from the remote tip (margin could not be measured)"
    elif [[ "$commits" =~ ^[0-9]+$ ]] && (( commits >= max_commits )); then
        trip=1; why="${commits} commits behind (threshold ${max_commits})"
    fi
    if (( trip == 0 )) && (( hours >= max_hours )); then
        trip=1; why="oldest undeployed commit is ${hours}h old (threshold ${max_hours}h)"
    fi
    if (( trip == 0 )); then
        rm -f "$state_dir/drift-clone" "$state_dir/drift-clone-surfaced" 2>/dev/null || true
        _clone_drift_log "behind by ${commits} commit(s) / ${hours}h — under thresholds (${max_commits}/${max_hours}h)"
        return 0
    fi

    _clone_drift_log "BEHIND origin/$branch: $why"
    _version_write_drift_record "$state_dir" clone "$head" "$tip" \
        "behind|${commits}|${hours}|${branch}|${why}"
    return 0
}
