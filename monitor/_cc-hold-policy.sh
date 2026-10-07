#!/usr/bin/env bash
# monitor/_cc-hold-policy.sh — the ONE classifier for "does this outcome HOLD
# a Claude Code update?", and the retry schedule that follows from it.
#
# THE POLICY (operator, 2026-09-27, your-org/nexus-code#1657):
#
#     "The cc-update should only be held if there is real concern nexus-code
#      could not work anymore … In other cases it is actually more costly if
#      we cannot update and all users are stuck on older cc and model
#      selection."
#
# So the default is to UPDATE, and exactly one class of outcome holds:
#
#   COMPAT      positive, candidate-attributed evidence that nexus-code
#               breaks on the candidate: a gate scenario that fails, or a
#               probe against the candidate binary that shows the breakage,
#               PLUS a baseline on which the same check did NOT fail (so the
#               failure is the candidate's, not the checkout's), PLUS the
#               issue the compat fix is tracked on. `apply.sh block` refuses
#               to record a COMPAT hold without all three. A COMPAT hold is
#               re-evaluated when the live clone's HEAD moves (the fix may
#               have landed) and on every daily fire regardless — there is no
#               state that waits for an operator.
#
#   NOT-COMPAT  everything else that failed to apply: a deferral, a refused
#               apply (gate evidence, changelog accounting, live-tree drift),
#               a gate that could not run or could not be attributed, a block
#               with no candidate-attributed evidence. None of these is a
#               statement that the candidate breaks nexus-code, so none of
#               them may hold the update. Each schedules a RETRY within hours
#               (CC_AUTO_RETRY_SECONDS) and is surfaced as OUR defect.
#
#   APPLIED     the candidate was installed.
#
#   AUDIT       an intermediate row (spawned, evidence rows, notes). Not an
#               outcome; never holds, never schedules anything.
#
# A decision word this file does not know is classified NOT-COMPAT: an unknown
# outcome is not evidence the candidate breaks anything, and the failure
# direction of "not a hold" is a RETRY, never a silent bump — nothing here
# writes a pin. This is the default arm, and it is deliberately the one that
# keeps the routine moving rather than the one that parks it.
#
# Side-effect-free on source. Functions read/write only the files named.

if [[ -n "${_NEXUS_CC_HOLD_POLICY_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_CC_HOLD_POLICY_LOADED=1

# Seconds until a NOT-COMPAT non-apply is re-evaluated. "Retry within hours,
# not tomorrow" (the operator); 3 h leaves room for the evaluator's own ~15
# minute run and for a tree fix to land in between.
: "${CC_AUTO_RETRY_SECONDS:=10800}"
# At most this many retry fires per calendar day (on top of the daily fire),
# so a NOT-COMPAT cause that persists costs a bounded number of evaluations.
: "${CC_AUTO_RETRY_MAX_PER_DAY:=4}"
# A COMPAT hold is re-evaluated early when the live HEAD moves, but not sooner
# than this after the block (a fix merging minutes after a block is rare; a
# HEAD that moves for unrelated reasons should not re-fire every tick).
: "${CC_AUTO_COMPAT_RECHECK_MIN_SECONDS:=3600}"

# The AUDIT vocabulary: intermediate rows that are not outcomes. Literal
# equality against this list (plus the `cc-floor-*` family), so no pattern arm
# can shadow the COMPAT arms above it (the #1121 arm-order rule).
_CC_HOLD_AUDIT_WORDS=" spawned surface-evidence changelog-completeness changelog-gap deployment-gate deployment-gate-instrument-failed deployment-gate-defect-UNFILED deployment-gate-defer-escalation restart-path-pr-noted pr-under-active-review-noted restart-path-pr-aged-out opaque-release-accepted safe-refused-repeat safe-refused-unapplied retry-scheduled retry-fired retry-requested retry-exhausted manual-refire gate-red-preexisting gated-tree-dirty-accepted evaluator-window-reclaimed skipped-window-alive skipped-window-alive-escalation block-attribution-corrected restart-abort-escalation skipped-compat-hold-same-day safe-refused-held "

# cc_hold_class <decision> [detail] — prints COMPAT | NOT-COMPAT | APPLIED | AUDIT.
# The HOLD arms come first; everything after them can only answer a class
# that does not hold, and the default is NOT-COMPAT (see the header).
cc_hold_class() {
    local decision="${1:-}" detail="${2:-}"
    # --- the hold -------------------------------------------------------
    # `block`: the contract writes `class=compat` at the head of the detail;
    # only `apply.sh block` with evidence+issue+control can. A LEGACY `block`
    # row (written before the contract existed) carries no class and is read
    # as COMPAT: conservative, and harmless, because a COMPAT hold is
    # re-evaluated daily anyway.
    if [[ "$decision" == "block" ]]; then
        if [[ "$detail" == class=not-compat* ]]; then
            printf 'NOT-COMPAT\n'
            return 0
        fi
        printf 'COMPAT\n'
        return 0
    fi
    if [[ "$decision" == "compat-pr-opened" || "$decision" == "compat-pr-commented" ]]; then
        printf 'COMPAT\n'
        return 0
    fi
    # --- applied --------------------------------------------------------
    if [[ "$decision" == safe-bumped* || "$decision" == "safe-applied" || "$decision" == "reconcile-fired" ]]; then
        printf 'APPLIED\n'
        return 0
    fi
    # --- intermediate / audit rows ---------------------------------------
    if [[ "$_CC_HOLD_AUDIT_WORDS" == *" $decision "* || "$decision" == cc-floor-* ]]; then
        printf 'AUDIT\n'
        return 0
    fi
    # --- everything else that did not apply --------------------------------
    # safe-deferred, safe-refused, block-unattributable, block-not-compat,
    # eval-safe-unapplyable, skipped-awaiting-operator, spawn-failed, …
    printf 'NOT-COMPAT\n'
}

# cc_hold_is_hold <decision> [detail] — rc 0 iff this outcome holds the update.
cc_hold_is_hold() {
    [[ "$(cc_hold_class "$@")" == "COMPAT" ]]
}

# cc_hold_block_contract <evidence> <issue> <control> — rc 0 iff a block
# carries what a COMPAT hold requires; otherwise prints the missing parts
# (space-separated) and returns 1. The SHAPE is checked, not presence alone:
#   evidence  gate:<scenario-name> | probe:<existing non-empty findings file>
#   issue     https://github.com/<o>/<r>/issues|pull/<N>  or  <o>/<r>#<N>
#   control   non-empty free text naming the baseline on which the same check
#             passed (e.g. "2.1.273: 27/27 arms pass"); a control that failed
#             identically is exactly the NOT-COMPAT case, and must not be given
cc_hold_block_contract() {
    local evidence="${1:-}" issue="${2:-}" control="${3:-}" missing=""
    case "$evidence" in
        gate:?*)
            [[ "${evidence#gate:}" =~ ^[A-Za-z0-9._-]+$ ]] || missing="$missing evidence(bad-scenario-name)" ;;
        probe:?*)
            [[ -s "${evidence#probe:}" ]] || missing="$missing evidence(probe-file-missing-or-empty)" ;;
        "") missing="$missing evidence" ;;
        *)  missing="$missing evidence(want-gate:<scenario>|probe:<file>)" ;;
    esac
    local url_re='^https://github[.]com/[^/[:space:]]+/[^/[:space:]]+/(issues|pull)/[0-9]+$'
    local ref_re='^[^/[:space:]]+/[^/[:space:]]+[#][0-9]+$'
    local issue_ok=0
    [[ "$issue" =~ $url_re ]] && issue_ok=1
    [[ "$issue" =~ $ref_re ]] && issue_ok=1
    (( issue_ok )) || missing="$missing issue"
    local c="${control//[[:space:]]/}"
    [[ -n "$c" ]] || missing="$missing control"
    if [[ -n "$missing" ]]; then
        printf '%s\n' "${missing# }"
        return 1
    fi
    return 0
}

# ---- retry schedule ---------------------------------------------------------
#
# ONE file, `<auto_dir>/retry-at`, key=value lines:
#   at=<epoch>  candidate=<v>  class=<COMPAT|NOT-COMPAT>  reason=<decision>
#   head=<sha the outcome was measured at, or unknown>
# A NOT-COMPAT retry is due at `at`. A COMPAT re-check is due at `at` AND only
# once the live HEAD differs from `head` (the fix landed); the daily fire
# re-evaluates a COMPAT hold regardless of HEAD.

# cc_hold_schedule_retry <auto_dir> <candidate> <decision> <detail> <now> [head]
# Writes retry-at for a non-applied outcome; clears it for an applied one;
# leaves it alone for an AUDIT row. Prints what it did (one line).
cc_hold_schedule_retry() {
    local dir="${1:?dir}" candidate="${2:?candidate}" decision="${3:?decision}"
    local detail="${4:-}" now="${5:-$(date +%s)}" head="${6:-unknown}"
    local cls; cls=$(cc_hold_class "$decision" "$detail")
    local f="$dir/retry-at"
    case "$cls" in
        APPLIED) rm -f "$f" 2>/dev/null; printf 'retry-cleared\n'; return 0 ;;
        AUDIT)   printf 'retry-unchanged\n'; return 0 ;;
    esac
    local delay="$CC_AUTO_RETRY_SECONDS"
    [[ "$cls" == "COMPAT" ]] && delay="$CC_AUTO_COMPAT_RECHECK_MIN_SECONDS"
    [[ "$delay" =~ ^[0-9]+$ ]] || delay=10800
    mkdir -p "$dir" 2>/dev/null || return 0
    local tmp="$f.tmp.$$"
    if printf 'at=%s\ncandidate=%s\nclass=%s\nreason=%s\nhead=%s\n' \
            "$(( now + delay ))" "$candidate" "$cls" "$decision" "$head" > "$tmp" 2>/dev/null \
       && mv -f "$tmp" "$f" 2>/dev/null; then
        printf 'retry-scheduled class=%s at=%s delay=%ss\n' "$cls" "$(( now + delay ))" "$delay"
    else
        rm -f "$tmp" 2>/dev/null
        printf 'retry-schedule-FAILED path=%s\n' "$f"
        return 1
    fi
}

# _cc_hold_field <file> <key> — value of key=... (first match), rc 1 if absent.
_cc_hold_field() {
    local f="$1" k="$2" v
    [[ -r "$f" ]] || return 1
    v=$(awk -v k="$k" 'index($0, k"=")==1 { print substr($0, length(k)+2); exit }' "$f" 2>/dev/null)
    [[ -n "$v" ]] || return 1
    printf '%s\n' "$v"
}

# cc_hold_retry_due <auto_dir> <now> <live_head> — rc 0 iff a scheduled retry
# is due now. Prints the reason on stdout (one line) either way.
#   rc 0 due · rc 1 not due / nothing scheduled · rc 3 exhausted for today
cc_hold_retry_due() {
    local dir="${1:?dir}" now="${2:?now}" live_head="${3:-unknown}"
    local f="$dir/retry-at" at cls head
    [[ -f "$f" ]] || { printf 'no-retry-scheduled\n'; return 1; }
    at=$(_cc_hold_field "$f" at) || at=""
    cls=$(_cc_hold_field "$f" class) || cls=""
    head=$(_cc_hold_field "$f" head) || head="unknown"
    # A malformed schedule is due NOW rather than never: "could not read when"
    # must not become "wait forever", which is the standing hold this file
    # exists to abolish.
    [[ "$at" =~ ^[0-9]+$ ]] || { printf 'retry-at-malformed\n'; return 0; }
    (( now >= at )) || { printf 'retry-not-yet at=%s\n' "$at"; return 1; }
    local today n
    today=$(date -d "@$now" +%F 2>/dev/null || date +%F)
    n=$(awk -v d="$today" '$1==d{c++} END{print c+0}' "$dir/retry-fires" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    local manual; manual=$(_cc_hold_field "$f" manual) || manual=0
    if [[ "$manual" != "1" ]] && (( n >= CC_AUTO_RETRY_MAX_PER_DAY )); then
        printf 'retry-exhausted today=%s fires=%s max=%s\n' "$today" "$n" "$CC_AUTO_RETRY_MAX_PER_DAY"
        return 3
    fi
    if [[ "$cls" == "COMPAT" && "$manual" != "1" ]]; then
        if [[ "$live_head" == "unknown" || "$head" == "unknown" || "$live_head" == "$head" ]]; then
            printf 'compat-hold-head-unchanged head=%s\n' "$head"
            return 1
        fi
        printf 'compat-recheck head-moved %s->%s\n' "$head" "$live_head"
        return 0
    fi
    printf 'retry-due class=%s at=%s\n' "${cls:-?}" "$at"
    return 0
}

# cc_hold_retry_consume <auto_dir> <now> — record that a retry fired (bounded
# per day) and drop the schedule; the outcome of the re-run writes a new one.
cc_hold_retry_consume() {
    local dir="${1:?dir}" now="${2:?now}"
    local today; today=$(date -d "@$now" +%F 2>/dev/null || date +%F)
    printf '%s %s\n' "$today" "$now" >> "$dir/retry-fires" 2>/dev/null || true
    rm -f "$dir/retry-at" 2>/dev/null || true
}

# cc_tree_dirty_digest <repo_root> — a digest of the TRACKED modifications
# (`git diff --binary HEAD`: staged + unstaged, tracked files only), or `none`
# for a tree with none, or `unknown` when git could not answer. gate.sh stamps
# it; apply.sh recomputes it on the live clone. Equal digests mean the gate
# RAN the tree whose pin moves, edits included — which is what a
# `gated-tree-dirty` refusal could not establish from `head=` alone
# (your-org/nexus-code#1657: that refusal held 2.1.258 and 2.1.259).
cc_tree_dirty_digest() {
    local root="${1:?root}" d rc
    # --no-ext-diff --no-textconv: a user's configured diff driver
    # (diff.external / GIT_EXTERNAL_DIFF) or a textconv filter would REPLACE the
    # bytes digested, and two different edits could then share one digest —
    # a dirty tree accepted as the one the gate ran (#1657 follow-up).
    d=$(git -C "$root" diff --no-ext-diff --no-textconv --binary HEAD 2>/dev/null); rc=$?
    (( rc == 0 )) || { printf 'unknown\n'; return 0; }
    [[ -n "$d" ]] || { printf 'none\n'; return 0; }
    printf '%s' "$d" | sha1sum | awk '{print $1}'
}

# cc_hold_request_retry <auto_dir> <candidate|-> <reason> <now> — the operator
# (or orchestrator) asks for a re-evaluation on the next watcher tick. Marked
# manual=1: exempt from the per-day retry cap and from the COMPAT head-moved
# condition, because a human asked.
cc_hold_request_retry() {
    local dir="${1:?dir}" candidate="${2:--}" reason="${3:?reason}" now="${4:-$(date +%s)}"
    mkdir -p "$dir" 2>/dev/null || return 1
    local f="$dir/retry-at" tmp="$dir/retry-at.tmp.$$"
    printf 'at=%s\ncandidate=%s\nclass=NOT-COMPAT\nreason=retry-requested\nhead=unknown\nmanual=1\nwhy=%s\n' \
        "$now" "$candidate" "${reason//$'\n'/ }" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
}

# cc_repo_head <root> — the HEAD of <root> ONLY when <root> is itself a
# repository's top level; `unknown` otherwise. `git -C` WALKS UP to an
# enclosing repository at rc 0 (CLAUDE.md, #1196), and every fixture root and
# every clone under work/ has one — a HEAD read there would be the nexus's.
cc_repo_head() {
    local root="${1:?root}" top real h
    top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || { printf 'unknown\n'; return 0; }
    real=$(cd "$root" 2>/dev/null && pwd -P) || { printf 'unknown\n'; return 0; }
    [[ "$(cd "$top" 2>/dev/null && pwd -P)" == "$real" ]] || { printf 'unknown\n'; return 0; }
    h=$(git -C "$root" rev-parse HEAD 2>/dev/null) || h=""
    [[ "$h" =~ ^[0-9a-f]{40}$ ]] && printf '%s\n' "$h" || printf 'unknown\n'
}
