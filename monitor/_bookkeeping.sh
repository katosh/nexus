#!/usr/bin/env bash
# _bookkeeping.sh — the two guard primitives behind the bookkeeping
# contract (your-org/nexus-code #599 #601 #602 #603 #605 #607 #615).
#
# Those eight issues are one defect with eight faces:
#
#   a signal reports a DEFINITE state for a condition the emitter
#   cannot actually distinguish, or a verb reports SUCCESS for work
#   it did not do.
#
# The contract, now mechanised here rather than described in prose:
#
#   1. Any verb that IGNORES a supplied argument must fail loudly
#      rather than succeed quietly.          → bk_require_int
#                                              bk_refuse_ignored
#   2. Any signal that CANNOT DISTINGUISH two states must say so
#      rather than pick one, and no destructive action may be
#      authorised by such a signal.          → bk_pane_kill_authorized
#
# Prose has already failed on every one of these. `pane-state.sh`
# documents `empty` as explicitly ambiguous ("treat as don't know yet")
# in its own header — and the retirement path killed windows on it
# anyway, because the gate was a `case` whose DEFAULT ARM PERMITTED.
# `ng wrap-up` documents `--skeptic-findings` as a count — and coerced
# prose to `0`, the value meaning "nothing found", on the control path
# of the gate whose entire purpose is to stop under-reported findings.
#
# So the primitives here are shaped to make the safe behaviour the one
# you get by DOING NOTHING:
#
#   * bk_pane_kill_authorized is an ALLOWLIST with a default-DENY arm.
#     A pane state nobody has thought about yet — including one added
#     by a future pane-state.sh — refuses the kill. Under the old
#     `case … *) : ;;` shape the same unknown state PERMITTED it. That
#     inversion is the whole fix; the specific `empty` bug is one
#     instance of it.
#   * bk_require_int refuses a malformed value instead of substituting
#     a default. There is no coercion path to fall into.
#
# Pure functions, no top-level side effects: safe to source from any
# script, and from a test that wants to drive the predicates directly.
#
# Error reporting convention: a failing predicate sets $BK_ERR to a
# caller-printable explanation and returns non-zero. It prints NOTHING
# itself, so the caller controls the prefix (`ng: …`, `retire-preflight:
# …`) and there is no double-reporting. Callers do:
#
#     bk_require_int --skeptic-findings "$v" || die "$BK_ERR"
#
# Guard against double-sourcing (ng sources this, and so does a script
# ng invokes).
[[ -n "${_BOOKKEEPING_SH_LOADED:-}" ]] && return 0
_BOOKKEEPING_SH_LOADED=1

# Set by every failing predicate below. Never read unless a predicate
# has just returned non-zero.
BK_ERR=""

# ---------------------------------------------------------------------------
# Contract 1 — a verb that ignores a supplied argument must fail loudly.
# ---------------------------------------------------------------------------

# bk_require_int <flag-name> <value> [--allow-empty]
#
# Accepts: an unsigned decimal integer. Also accepts EMPTY when
# --allow-empty is passed (the flag-was-not-supplied case, which is a
# genuine absence rather than a malformed value — the caller then keeps
# its own default).
#
# Refuses everything else. In particular it NEVER substitutes 0: that
# is the #601 defect verbatim. `--skeptic-findings "four findings, one
# HIGH and merge-blocking"` became `findings=0`, which made
# `substantive = verdict ∈ {suspect,refuted} || findings >= thresh`
# false, which printed "Skeptic chain TERMINATES: no substantive new
# issues" and suppressed the second-pass recommendation. Silent,
# plausible, wrong, and in the failure direction that hides findings.
#
# The natural mistake it must catch: every NEIGHBOURING skeptic flag
# (--skeptic-rationale, --skeptic-contradicted, --skeptic-waive) takes
# free text, so prose here is the expected slip, not an exotic one.
bk_require_int() {
    local flag="$1" value="${2-}" allow_empty=0
    [[ "${3:-}" == "--allow-empty" ]] && allow_empty=1
    if [[ -z "$value" ]]; then
        if (( allow_empty == 1 )); then
            return 0
        fi
        BK_ERR="$flag requires a value (an unsigned integer); got an empty argument"
        return 1
    fi
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    BK_ERR="$flag must be an unsigned integer, got: '$value'
  Refusing rather than coercing. A non-numeric count silently became 0 —
  the value that means \"nothing found\" — and terminated the skeptic
  chain against the skeptic's own verdict (your-org/nexus-code#601).
  If you meant to record prose, that is --skeptic-rationale."
    return 1
}

# bk_refuse_ignored <what> <why> <remedy>
#
# The general tripwire for contract 1: a verb has reached a branch in
# which a SUPPLIED argument would have no effect. Rather than proceed
# and exit 0 (the #605 defect — `--comment-body-file` dropped on a
# repeat wrap-up while printing `UPDATED` and exiting 0), the caller
# calls this and fails.
#
# Composing the message here rather than at each site keeps the shape
# uniform and greppable, so a future instance of this class is
# recognisable as one.
bk_refuse_ignored() {
    local what="$1" why="$2" remedy="${3:-}"
    BK_ERR="$what was supplied but this code path would IGNORE it — refusing.
  why: $why"
    [[ -n "$remedy" ]] && BK_ERR+="
  do instead: $remedy"
    return 1
}

# ---------------------------------------------------------------------------
# Contract 2 — a signal that cannot distinguish two states must say so,
# and must never authorise a destructive action.
# ---------------------------------------------------------------------------

# The pane states that AUTHORISE retiring (killing) a window.
#
# Membership rule — a state qualifies iff it asserts, positively, that
# no turn is in flight and no operator input is pending. "We could not
# tell" is not such an assertion, and neither is "the agent is
# suspended".
#
#   idle              definite: turn ended, input box empty.
#   autosuggest-only  definite: idle, with cosmetic ghost text only.
#   absent            definite: NO live `claude` in the pane's process
#                     tree. This is the state that actually means
#                     "finished" — pane-state.sh distinguishes it from
#                     `empty` precisely (renderer empty AND process
#                     dead), and it is the gate the retirement path
#                     should have been using all along.
#   idle-orphan-async definite-idle; the async-contract violation it
#                     denotes is an operator-surfacing concern, not a
#                     liveness one. Unchanged from prior behaviour.
#
# Everything else refuses, and the two groups refuse for DIFFERENT
# reasons, which the caller reports distinctly:
#
#   INDETERMINATE — `empty`, `unknown`, and anything unrecognised.
#   ACTIVE        — busy, user-typing, blocked, working-*, over-limit,
#                   queued.
#
# `over-limit` moves here from the old permissive default arm. It was
# never safe to kill: skills/nexus.window-cleanup has always said "Do
# NOT close — closing forfeits loaded context and the pending in-flight
# work", yet the preflight's `*)` arm permitted it. Same defect class,
# found while fixing #603.
#
# `queued` is listed although pane-state.sh emits `busy queued=1` rather
# than a distinct state — so that IF a future revision promotes it to a
# state, the gate already refuses instead of inheriting a permit.
_BK_KILL_OK_STATES=(idle autosuggest-only absent idle-orphan-async)
_BK_ACTIVE_STATES=(busy user-typing blocked working-background
                   working-self-paced over-limit queued)

# bk_pane_kill_authorized <pane-state>
#
# rc 0  → the state positively asserts the window is finished; a kill
#         may proceed.
# rc 1  → refuse. $BK_ERR explains which of the two refusal reasons
#         applies, and $BK_REFUSE_KIND is set to `active` or
#         `indeterminate` for callers that branch on it.
#
# DEFAULT-DENY is the point. The predecessor was
#
#     case "$pane_state" in
#         user-typing) refuse ;;
#         busy|working-*) refuse ;;
#         blocked) refuse ;;
#         unknown) refuse ;;
#         *) : ;;                 # <-- everything else PERMITTED
#     esac
#
# which permitted `empty` — documented four times in one night as
# "don't know" — and would have killed a pane 4m38s into a verification
# pass with a message still queued behind it. Enumerating what is SAFE
# and denying the rest cannot fail that way: a state you forgot to think
# about lands in the deny arm.
bk_pane_kill_authorized() {
    local state="${1-}" s
    BK_REFUSE_KIND=""
    for s in "${_BK_KILL_OK_STATES[@]}"; do
        [[ "$state" == "$s" ]] && return 0
    done
    for s in "${_BK_ACTIVE_STATES[@]}"; do
        if [[ "$state" == "$s" ]]; then
            BK_REFUSE_KIND=active
            BK_ERR="pane state '$state' means the window is ACTIVE or suspended, not finished — refusing kill"
            return 1
        fi
    done
    BK_REFUSE_KIND=indeterminate
    BK_ERR="pane state '$state' does not assert that the window is finished — refusing kill.
  '$state' is an INDETERMINATE reading (\"don't know yet\"), not a liveness
  verdict. The state that positively asserts a dead agent is 'absent'
  (renderer empty AND no live claude in the pane's process tree); wait for
  that, or for a plain 'idle', and retry. See your-org/nexus-code#603."
    return 1
}

# States that POSITIVELY assert a dead agent. Exactly one, and that is
# not an oversight: `absent` is defined as renderer-empty AND no live
# claude in the pane's process tree. Everything else — `empty`
# emphatically included — is a reading that has not established death.
_BK_DEAD_STATES=(absent)

# bk_pane_asserts_dead <pane-state>
#
# rc 0  → the state positively asserts the agent is gone.
# rc 1  → it does not. Includes every indeterminate reading, every
#         active state, and any state this file has never heard of.
#
# THE DUAL OF bk_pane_kill_authorized, NOT ITS NEGATION (nexus-code#771).
# Both are default-deny; they differ in WHICH action is the dangerous one,
# so they deny opposite things and a caller must not substitute one for
# the other:
#
#   * for a KILL, the dangerous act is killing a live worker, so the
#     unknown state must NOT authorise the kill → default deny;
#   * for "is a reviewer already on this?", the dangerous act is
#     asserting that NOBODY is, so the unknown state must NOT produce
#     that assertion → default deny death, i.e. presume alive.
#
# Running the states through `bk_pane_kill_authorized` and reading rc 0
# as "gone" would get this exactly backwards: `idle` is kill-authorised,
# and an `idle` skeptic is the single most re-pinnable state there is —
# a reviewer that has delivered a verdict and is waiting for the next
# delta. That is the #771 case verbatim.
bk_pane_asserts_dead() {
    local state="${1-}" s
    for s in "${_BK_DEAD_STATES[@]}"; do
        [[ "$state" == "$s" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Contract 4 — an operator-facing "needs you" row must be about NOW.
# ---------------------------------------------------------------------------
#
# States that positively assert the pane is NOT waiting on a human. Each
# one says something is ALREADY driving the pane forward, so an
# operator-facing decision row about it is answering a question nobody is
# being asked:
#
#   busy                 a turn is running
#   working-background   a background shell/handle is doing the work
#   working-self-paced   the agent scheduled its own next wake-up
#   user-typing          a human is demonstrably at this keyboard already
#
# NOT here, deliberately, and each absence is a ruling:
#
#   blocked            THE case the channel exists for — a permission /
#                      overlay modal that only a human clears. Must emit.
#   idle               waiting for input is what the row reports.
#   autosuggest-only   `idle` wearing ghost text. A genuinely idle worker
#                      very often renders autosuggest, so withholding it
#                      would silence real idles to buy quiet on parked
#                      ones. Parked-by-instruction is ORCHESTRATOR
#                      knowledge, not a pane fact; the durable ack
#                      (`ng decision-ack`) is where that knowledge belongs.
#   over-limit         no human can shorten a quota reset, but the pane is
#                      suspended rather than progressing, and the operator
#                      may want to re-route the work. Erring loud.
#   absent             the agent died with a decision outstanding. Not
#                      answerable in-pane, but it is emphatically an
#                      action item.
#   empty / unknown    indeterminate readings. See the direction note.
#
# THIRD MEMBER OF THE bk_pane_* FAMILY, AND IT DEFAULTS THE OTHER WAY.
# That is not an oversight, it is the same rule applied to a different
# dangerous act. bk_pane_kill_authorized default-denies because killing a
# live worker is the harm. bk_pane_asserts_dead default-denies death
# because "nobody is reviewing this" is the harm. Here the harm is
# SILENCING a genuine block: an emit channel that swallows the one real
# row is strictly worse than one that carries three spurious ones, because
# the spurious rows cost an inspection while the swallowed row costs a
# stalled worker nobody is looking for. So the default arm EMITS, and a
# state this file has never heard of — including one a future
# pane-state.sh adds — surfaces rather than vanishes.
#
# The coverage that makes the default arm safe rather than lazy is pinned
# as DATA: monitor/watcher/decision-gate-states.manifest carries a row per
# member of `pane-state.sh --states`, and
# monitor/watcher/test-decision-gate-states.sh fails when a state exists
# with no ruling here. Prose cannot be made to fail; that manifest can.
_BK_DECISION_MOOT_STATES=(busy working-background working-self-paced user-typing)

# bk_decision_row_actionable <pane-state> [<queued>]
#
# rc 0  → surface the decision row: nothing about the pane's current state
#         rules out "a human's answer is what unblocks this".
# rc 1  → withhold. $BK_ERR names why; the decision FILE is untouched, so
#         the row returns the moment the pane stops asserting otherwise.
#
# <queued> is the `queued=1` token from the same pane-state line, passed as
# `1` when present. A pane with input already waiting behind a running turn
# is not awaiting an operator — and re-surfacing it invites exactly the
# double-paste your-org/nexus-code#607 warns against, so it withholds
# regardless of the state token.
bk_decision_row_actionable() {
    local state="${1-}" queued="${2-}" s
    BK_ERR=""
    if [[ "$queued" == "1" ]]; then
        BK_ERR="pane has input QUEUED behind a running turn — an answer is already in flight (your-org/nexus-code#607); withholding the row"
        return 1
    fi
    for s in "${_BK_DECISION_MOOT_STATES[@]}"; do
        if [[ "$state" == "$s" ]]; then
            BK_ERR="pane state '$state' means the pane is being driven forward already, not waiting on a human — withholding the row"
            return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Retirement teardown manifest (your-org/nexus-code#602).
# ---------------------------------------------------------------------------
#
# Retiring a wrapped worker used to be a HAND-COPIED CHECKLIST of state
# directories, transcribed at each retirement from
# skills/nexus.window-cleanup. `idle-state.tsv` was not on that list and
# nothing else pruned it, so EVERY retirement of a wrapped worker left a
# phantom row that kept the window in the `--- idle workers ---` emit
# forever. `kompot-panelL` kept firing `wrapped up (idle 218s)` on every
# poll tick for a window that no longer existed in tmux.
#
# The corrosive part is not the noise. `--- idle workers ---` is the
# orchestrator's primary situational-awareness surface; once it is known
# to contain entries that aren't real, it stops being trusted, and a
# GENUINE idle worker gets ignored along with the phantoms. A noisy but
# accurate list is strictly better than a quiet unreliable one.
#
# Adding one more path to the checklist would have been the wrong shape
# of fix: the checklist has now been wrong at least once, and one that
# must be transcribed correctly at every retirement will drift again. So
# the list lives HERE, once, as data — read by the `ng retire-window`
# teardown AND by the test that asserts no surface retains a reference
# to a retired window. Adding a surface to this array extends both, and
# the test fails for any surface the teardown misses.
#
# Entry syntax:  <kind>:<path-template>
#   file:<p>    a single file; removed if present.
#   dir:<p>     a directory; removed recursively.
#   prefix:<p>  every entry whose name begins with <p>.
#   tsv:<p>     rows of a TSV whose FIRST column equals the window.
# Templates expand {w} = the raw window name, {s} = the same name
# sanitised to [A-Za-z0-9_-] (the convention used for names that must be
# safe as a single path component).
#
# NOT included, deliberately: action-log.jsonl and the reports corpus.
# Those are the audit trail — the record that a retirement HAPPENED —
# and pruning them would destroy the evidence that makes a retirement
# reconstructable. functional-check.tsv is excluded because it is not
# window-keyed (its first column is an epoch), so a window-name match
# there would be a coincidence, not a reference.
BK_RETIRE_SURFACES=(
    "file:user-prompt/{w}"
    "file:machine-submit/{w}"
    "file:heartbeat/{w}.json"
    "file:pane-change/{w}"
    "file:spawn-prompts/{w}.txt"
    "file:worker-health/{w}.json"
    "file:bg-backoff/{w}"
    "file:bg-firstseen/{w}"
    "file:windows/{s}.json"
    "file:skeptic/pending/{s}"
    "dir:skeptic/{s}"
    "prefix:decisions/{w}."
    "prefix:footgun-seen/{w}."
    "tsv:idle-state.tsv"
    "tsv:engagement-log.tsv"
    "tsv:operator-engaged.tsv"
    "tsv:over-limit-state.tsv"
    "tsv:machine-input.tsv"
)

# bk_retire_surface_path <template> <window>
# Expand one manifest template's path part for <window>.
bk_retire_surface_path() {
    local tmpl="$1" window="$2" safe="${2//[^a-zA-Z0-9_-]/_}"
    local path="${tmpl#*:}"
    path="${path//\{w\}/$window}"
    path="${path//\{s\}/$safe}"
    printf '%s' "$path"
}

# bk_retire_surface_kind <template>
bk_retire_surface_kind() { printf '%s' "${1%%:*}"; }

# bk_state_refs_window <state-dir> <window>
#
# Print one line per manifest surface that STILL references <window>,
# as `<kind>\t<path>`. Empty output means the teardown is complete.
#
# This is the predicate the test asserts on, and it is derived from the
# manifest rather than restating it — a surface added to
# BK_RETIRE_SURFACES is checked here without touching this function.
bk_state_refs_window() {
    local state_dir="$1" window="$2" entry kind path p
    for entry in "${BK_RETIRE_SURFACES[@]}"; do
        kind=$(bk_retire_surface_kind "$entry")
        path=$(bk_retire_surface_path "$entry" "$window")
        case "$kind" in
            file) [[ -e "$state_dir/$path" ]] && printf 'file\t%s\n' "$path" ;;
            dir)  [[ -d "$state_dir/$path" ]] && printf 'dir\t%s\n'  "$path" ;;
            prefix)
                for p in "$state_dir/$path"*; do
                    [[ -e "$p" ]] || continue
                    printf 'prefix\t%s\n' "${p#"$state_dir/"}"
                done ;;
            tsv)
                if [[ -f "$state_dir/$path" ]] \
                   && awk -F'\t' -v w="$window" '$1 == w { found = 1 } END { exit(found ? 0 : 1) }' \
                        "$state_dir/$path" 2>/dev/null; then
                    printf 'tsv\t%s\n' "$path"
                fi ;;
        esac
    done
    return 0
}

# bk_prune_window_state <state-dir> <window>
#
# Remove every manifest surface's reference to <window>. Best-effort per
# surface (a failure on one must not strand the rest), but the caller
# verifies with bk_state_refs_window afterwards rather than trusting
# this to have succeeded — checking the property, not the proxy.
bk_prune_window_state() {
    local state_dir="$1" window="$2" entry kind path p tmp
    [[ -n "$state_dir" && -n "$window" && -d "$state_dir" ]] || return 1
    for entry in "${BK_RETIRE_SURFACES[@]}"; do
        kind=$(bk_retire_surface_kind "$entry")
        path=$(bk_retire_surface_path "$entry" "$window")
        case "$kind" in
            file) rm -f  "$state_dir/$path" 2>/dev/null || true ;;
            dir)  rm -rf "$state_dir/$path" 2>/dev/null || true ;;
            prefix)
                for p in "$state_dir/$path"*; do
                    [[ -e "$p" ]] || continue
                    rm -rf "$p" 2>/dev/null || true
                done ;;
            tsv)
                [[ -f "$state_dir/$path" ]] || continue
                tmp="$state_dir/$path.retire.$$"
                if awk -F'\t' -v w="$window" '$1 != w' "$state_dir/$path" > "$tmp" 2>/dev/null; then
                    mv -f "$tmp" "$state_dir/$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
                else
                    rm -f "$tmp" 2>/dev/null || true
                fi ;;
        esac
    done
    return 0
}

# bk_state_is_indeterminate <pane-state>
#
# True for the readings that carry no information about liveness. Kept
# separate from the kill gate so callers that merely want to SKIP a
# window this cycle (rather than authorise a kill) can ask the narrower
# question without inheriting the gate's active/finished distinction.
bk_state_is_indeterminate() {
    local state="${1-}" s
    for s in "${_BK_KILL_OK_STATES[@]}" "${_BK_ACTIVE_STATES[@]}"; do
        [[ "$state" == "$s" ]] && return 1
    done
    return 0
}
