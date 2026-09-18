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
# Contract 0 — a key that names a window must name exactly ONE window.
# (your-org/nexus-code#941)
# ---------------------------------------------------------------------------
#
# `${w//[^a-zA-Z0-9_-]/_}` is MANY-TO-ONE. `a.b` and `a_b` collapse to the same
# key, so two DISTINCT windows share one state file. That has been true for as
# long as the sanitiser has existed.
#
# THE PROMOTION IS THE FINDING, NOT THE COLLISION. A latent many-to-one mapping
# became a SAFETY defect the moment a consumer keyed an irreversible decision
# on it — and measured on `dev` at e256d4a, that had already happened twice
# before anybody looked:
#
#   * `ng wrap-up --skeptic-role` clears `skeptic/pending/<key>` when a verdict
#     is filed. A verdict for `a.b` DELETES `a_b`'s require-gate, so `a_b`
#     retires with its required skeptic never having run. retire-preflight
#     check 1b is the gate; the collision walks straight through it.
#   * `bk_prune_window_state` deletes by `{s}`. Retiring `a.b` destroyed
#     `a_b`'s `windows/a_b.json`, its require-gate and its whole skeptic
#     channel dir — while LEAVING `user-prompt/a_b` and `heartbeat/a_b.json`,
#     because those templates use `{w}`. A half-torn-down window is worse than
#     either extreme: nobody retired it, and `bk_state_refs_window` now reports
#     leftovers for it forever.
#
# `your-org/nexus-code#926` (retire-preflight check 1d, the obligation ledger)
# added a THIRD such consumer. It is not where the promotion happened.
#
# ── The encoding ─────────────────────────────────────────────────────────
#
# Percent-encoding with `[A-Za-z0-9_-]` passed through and EVERY other byte as
# `%XX`. `%` is not in the pass-through set, so it encodes to `%25` and cannot
# be confused with an escape it did not introduce. Decoding is a left-to-right
# scan, so the map is INJECTIVE — a collision is impossible, not merely
# unlikely. That distinction is the requirement: narrowing the window would
# leave the same defect with a smaller cross-section.
#
# ── Why this migrates NOTHING, measured rather than hoped ─────────────────
#
# The pass-through set is EXACTLY the old sanitiser's output alphabet, so
# `wk_encode` is the IDENTITY on every name that did not need sanitising —
# which is every name this nexus has ever recorded:
#
#     $ for f in monitor/.state/windows/*.json; do jq -r '.window // empty' "$f"; done \
#         | sort -u | tee /tmp/n | wc -l                      # 1152 distinct names
#     $ grep -vc '^[A-Za-z0-9_-]*$' /tmp/n                    # 0 need encoding
#
# 1152 provenance records, 1152 distinct raw names, **0** that change key and
# **0** that collide today. So no existing record moves and none is orphaned.
# The defect is real and latent: it has never fired because no name in use
# needs sanitising, which is precisely why it kept reading as cosmetic.
#
# ── Records in flight at the moment of upgrade ────────────────────────────
#
# A window whose name DOES need encoding (a dotted `cc-update-2.1.183` is the
# real shape) and that was spawned before this landed has state under the old
# key. Readers must not silently miss it, so the rule is asymmetric and each
# half points the safe way:
#
#   READ / GATE   `wk_legacy_key` is consulted when the new key is absent, and
#                 a hit BLOCKS with a diagnostic. "A marker exists that might
#                 be ours" is doubt, and doubt refuses an irreversible act.
#   DESTRUCTIVE   never. A legacy key is exactly the one that cannot be
#                 attributed to a single window, so `bk_prune_window_state`
#                 removes only the NEW key and leaves the legacy file to be
#                 reported by `bk_state_refs_window` as an unattributable
#                 leftover. Loud and incomplete beats silent and wrong.
#
# ── THE DECLARED EXEMPTION: the `{w}` subtree is RAW, and that is a choice ─
#
# EIGHT of the retire-teardown surfaces are templated `{w}` — the raw window
# name, NOT the key. The count is what
#     grep -cE '"\w+:[^"]*\{w\}' monitor/_bookkeeping.sh
# reports at the commit that added this note; it is stated with its command
# because a bare number in a comment is the first thing to rot: `user-prompt/{w}`, `machine-submit/{w}`,
# `heartbeat/{w}.json`, `pane-change/{w}`, `worker-health/{w}.json`,
# `bg-backoff/{w}`, `bg-firstseen/{w}`, and the `decisions/{w}.` prefix.
# `spawn-prompts` is NOT among them — it was, wrongly, and this note certified
# it; see that entry. They are OUTSIDE the injectivity invariant, and
# saying so here is the point: an invariant with an undeclared exemption is
# indistinguishable from an invariant that is quietly false.
#
# WHY THEY ARE SOUND. The raw name is trivially injective — it is the identity
# — so two distinct windows can never share a `{w}` path. That is a STRONGER
# guarantee than `wk_encode` gives, not a weaker one, and it is why converting
# them would be a regression rather than a completion.
#
# WHERE THAT GUARANTEE ENDS, stated because it is the part a reader cannot
# infer: a raw name is a safe path component only while it contains no `/`
# and no NUL. A window named `a/b` writes `user-prompt/a/b` — a nested path,
# not a file — and the surface silently lands somewhere nobody reads. No such
# name exists here (1152 of 1152 are `[A-Za-z0-9_-]`, so none contains `/`),
# and tmux window names admit `/`, so this is a live if unexercised boundary.
# It is a DIFFERENT defect from the one this contract closes, and it is left
# open deliberately rather than silently: keying these by `wk_encode` would
# close it, at the cost of orphaning every existing `{w}` file.
#
# So: `{s}` surfaces are injective by encoding, `{w}` surfaces are injective
# by identity, and the `{w}` set additionally requires a `/`-free name. Both
# halves are declared; neither is assumed.

# wk_encode <name> — the injective state-file key for a window name.
wk_encode() {
    local LC_ALL=C s="${1-}"
    # Fast path, and it is the measured 1152-of-1152 case: a name already in
    # the pass-through alphabet encodes to itself. Also keeps this off the
    # per-character loop on the hot lookup paths.
    case "$s" in
        *[!A-Za-z0-9_-]*) ;;
        *) printf '%s' "$s"; return 0 ;;
    esac
    local out="" i c
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9_-]) out+="$c" ;;
            *) printf -v out '%s%%%02X' "$out" "'$c" ;;
        esac
    done
    printf '%s' "$out"
}

# wk_decode <key> — the inverse of wk_encode.
#
# It exists to make INJECTIVITY DEMONSTRABLE rather than asserted. A map is
# injective iff it has a left inverse, so `wk_decode "$(wk_encode "$x")" == "$x"`
# over an adversarial input set is a witness, not an opinion — and that is the
# difference between "collisions are impossible" and "I could not think of
# one". No production path calls it; the suite does.
wk_decode() {
    local LC_ALL=C k="${1-}" out="" i c h
    for (( i = 0; i < ${#k}; i++ )); do
        c="${k:i:1}"
        if [[ "$c" == "%" ]]; then
            h="${k:i+1:2}"
            if [[ "$h" =~ ^[0-9A-Fa-f]{2}$ ]]; then
                printf -v out '%s%b' "$out" "\\x$h"
                i=$(( i + 2 ))
                continue
            fi
            # A bare `%` cannot appear in a key wk_encode produced. Report the
            # input as undecodable rather than inventing a plausible answer.
            return 1
        fi
        out+="$c"
    done
    printf '%s' "$out"
}

# ── A SECOND ALPHABET: `[A-Za-z0-9_-]`, because one consumer cannot spell `%` ─
#
# your-org/nexus-code#960. `wk_encode` is the injective STATE key and it emits
# `%XX`. The request channel's `--origin` is a FILENAME component and validates
# `^[A-Za-z0-9_-]+$` (`request-channel.sh`), so `%` is rejected there — which is
# why `ng`'s spawn-skeptic filer reached for the OLD lossy sanitiser instead,
# and why `lossy ∘ injective` is lossy no matter which end you fix. A writer and
# a reader that AGREE cannot detect this: the pre-image is destroyed upstream of
# the encoder.
#
# So the channel needs its own encoding, injective into a NARROWER alphabet than
# `wk_encode`'s. `_` is the escape, and the escape must escape itself:
#
#     [A-Za-z0-9-]  pass through
#     _             `__`
#     anything else `_XX`, uppercase hex
#
# `_` is not a hex digit, so `__` and `_XX` can never be confused: a left-to-
# right scan decides on the character after `_` with no lookahead beyond it.
# Injective, and `wk_decode_word` is the left inverse that proves it.
#
# ── WHAT IT IS *NOT* THE IDENTITY ON, stated because `wk_encode` IS ────────
#
# `wk_encode`'s pass-through set is exactly the old sanitiser's output alphabet,
# so it moves no existing key. THIS one cannot make that claim: `_` is in the
# validator's alphabet AND is the escape, so `a_b` -> `a__b`. That is a real key
# change and it is declared here rather than discovered later.
#
# The blast radius is bounded and transient BY CONSTRUCTION, and it is worth
# stating why rather than asserting it is small. This key names nothing durable:
# it is a request-inbox filename component, and the only thing that reads it is
# an idempotency glob over requests still awaiting adjudication. A key change
# therefore costs at most one duplicate request per in-flight `_`-bearing
# window, once. It keys NO state directory — `windows/`, `skeptic/pending/` and
# the ledger are all `wk_encode`, and #960's F2 was precisely a site that had
# confused the two.
#
# ── THE DOWNSTREAM CONSUMER THAT TREATS AN ORIGIN AS A WINDOW NAME ────────
#
# `request-channel.sh`'s spawn-skeptic DECLINE path reads the request's `origin`
# frontmatter and passes it to `skeptic-channel.sh resolve <window>` — i.e. an
# origin is consumed as a window name, and the resolve DISCHARGES A REQUIRE
# GATE. Under the old lossy key that is a silent cross-window mutation: a
# decline on `a.b`'s request discharges `a_b`'s gate and leaves `a.b`'s armed.
#
# Under this encoding it becomes LOUD instead. `a.b` files origin `a_2Eb`, no
# such window has a gate, and `cmd_resolve` refuses a silent no-op — so
# `request-channel.sh` refuses to record the decline rather than discharging
# somebody else's. That is a strictly better failure and it is the reason this
# is an encoding rather than a fail-closed refusal at filing time: the REVIEW
# still gets requested, and only the decline sub-path degrades, loudly.
#
# It is deliberately NOT decoded at that site. `--origin` also carries values
# this function never produced (the remote path forces `remote-<principal>`), so
# decoding an arbitrary origin would be the same "two functions wearing one
# name" error one level along: `remote-a_bc` is not an encoded key, and treating
# it as one silently yields `remote-a<0xBC>`. A key is invertible only for the
# producer that made it.

# wk_encode_word <name> — injective into `[A-Za-z0-9_-]`, for consumers that
# cannot spell `%`. NOT the identity on names containing `_`; see above.
wk_encode_word() {
    local LC_ALL=C s="${1-}"
    # Fast path — and note `_` is NOT in it, unlike `wk_encode`'s. A name
    # carrying `_` must go through the loop so the escape gets doubled.
    case "$s" in
        *[!A-Za-z0-9-]*) ;;
        *) printf '%s' "$s"; return 0 ;;
    esac
    local out="" i c
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9-]) out+="$c" ;;
            _)            out+="__" ;;
            *) printf -v out '%s_%02X' "$out" "'$c" ;;
        esac
    done
    printf '%s' "$out"
}

# wk_decode_word <key> — the left inverse of wk_encode_word, so
# `wk_decode_word "$(wk_encode_word "$x")" == "$x"` for every `$x`. rc 1 on a
# string this encoder could not have produced — ALL of them, not a subset
# (your-org/nexus-code#1354): a trailing bare `_`; `_` followed by anything
# that is neither `_` nor two UPPERCASE hex digits (the encoder emits `%02X`,
# never lowercase); and a well-formed `_XX` whose byte the encoder would have
# PASSED THROUGH (`[A-Za-z0-9-]`) or spelled `__` (`_5F`). Those last were
# accepted until #1354 — `_5F` -> `_`, `_2D` -> `-`, `_41` -> `A` — so the
# function refused the malformed and invented a pre-image for the impossible.
# Refusing is the point — inventing a plausible pre-image is the failure this
# whole family is about, and a left inverse that also accepts strings outside
# the encoder's image is not the strict inverse its name claims.
wk_decode_word() {
    local LC_ALL=C k="${1-}" out="" i c h b
    for (( i = 0; i < ${#k}; i++ )); do
        c="${k:i:1}"
        if [[ "$c" == "_" ]]; then
            if [[ "${k:i+1:1}" == "_" ]]; then
                out+="_"; i=$(( i + 1 )); continue
            fi
            h="${k:i+1:2}"
            if [[ "$h" =~ ^[0-9A-F]{2}$ ]]; then
                printf -v b '%b' "\\x$h"
                # Outside the image: the encoder never hex-escapes a
                # pass-through byte, and spells `_` as `__`.
                case "$b" in [A-Za-z0-9_-]) return 1 ;; esac
                out+="$b"
                i=$(( i + 2 )); continue
            fi
            return 1
        fi
        out+="$c"
    done
    printf '%s' "$out"
}

# wk_legacy_key <name> — the OLD many-to-one key. For dual-READ only; never
# for a write and never for a delete.
wk_legacy_key() { printf '%s' "${1//[^a-zA-Z0-9_-]/_}"; }

# wk_needs_encoding <name> — rc 0 when this name's new key differs from its
# legacy key, i.e. when a legacy-keyed file for it may exist AND may belong to
# somebody else. Callers use this to decide whether a legacy lookup is even
# meaningful; for every name currently in use it is rc 1 and the whole
# dual-read path is skipped.
wk_needs_encoding() {
    [[ "$(wk_encode "${1-}")" != "$(wk_legacy_key "${1-}")" ]]
}

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
#
# `throttled` is the second such pre-registration, and it exists because the
# hazard it names ARRIVED (your-org/nexus-code#1340). Claude Code's
# `/low-priority` mode paints `✻ Working at lower priority · waiting for
# capacity · next try in 3s · attempt 2 · esc to interrupt` on a pane that is
# mid-turn and generating no tokens; `_detect_busy` keyed on the token
# counter, so the pane read `idle` — and `idle` is on the ALLOW list four
# lines down. A live worker retrying for capacity was kill-authorised by the
# gate that exists to prevent exactly that, which is the 2026-06-15 incident
# class reopened by a NEW HARNESS CAPABILITY rather than by a hand-copied
# state list. pane-state.sh now emits `busy throttled=1`; this row is the
# standing permit-refusal for the day somebody promotes the field.
_BK_KILL_OK_STATES=(idle autosuggest-only absent idle-orphan-async)
# `auth-login` / `auth-expired` are the THIRD pre-registration
# (your-org/nexus-code#1518), and they are here for exactly the reason `queued`
# and `throttled` are: `pane-state.sh` carries the login surface as a FIELD
# (`auth=login|expired`) rather than as a state token, so nothing emits these
# today — and if a future revision promotes the field, this gate REFUSES a kill
# instead of inheriting a permit from the fall-through arm. The hazard is the
# measured one: a logged-out orchestrator classifies `state=idle`, which is on
# the ALLOW list two lines up, so an auth surface that ever became a token and
# was not enumerated here would be kill-authorised by the gate built to stop
# precisely that.
_BK_ACTIVE_STATES=(busy user-typing blocked working-background
                   working-self-paced over-limit queued throttled
                   auth-login auth-expired)

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

# bk_is_transient_window_name <window-name>
#
# rc 0  → the name is a TRANSIENT tmux artefact, not a window any agent
#         occupies. rc 1 → it is an ordinary window name.
#
# The only member today is the `•`-prefixed dead-pane phantom. Windows
# spawned by monitor/spawn-worker.sh pin tmux `automatic-rename` and
# `allow-rename` to `off` precisely because a pane kept alive by
# `remain-on-exit on` gets retitled by tmux or by an OSC escape emitted
# from inside it — "most visibly to `•bell`" (spawn-worker.sh:32).
# `sandbox-notify` is a known producer, and this repo's own worker floor
# instructs every worker to call it, so the phantom is a routine
# occurrence rather than an exotic one.
#
# WHY THIS EXISTS AS A PREDICATE AND WHAT IT DOES NOT COVER
# (your-org/nexus-code#1492). Four consumers already dropped `^•` and the
# cc-auto-update deployment gate did not, so a phantom entered the gate's
# live-agent population, read `unreadable`, hit `_gate_window_may_hold_state`'s
# default-deny arm and DEFERRED a fully-evidenced bump. The count was wrong
# too — `live_windows=2` where the true agent count was 1.
#
# It is a BASH predicate and it deliberately converts only ONE of the four:
#
#   monitor/watcher/main.sh:1398  (snapshot_local)    awk '$1 !~ /^•/'
#   monitor/watcher/main.sh:1774  (list_bell_windows) awk '$2 !~ /^•/'
#   monitor/watcher/_idle_probe.sh:362                awk '$1 ~ /^•/ { next }'
#   monitor/bootstrap-recover.sh:1014                 awk '$1 !~ /^•/'
#
# THREE OF THOSE FOUR SIT INSIDE awk PROGRAMS, where a shell function is
# unreachable — so #1492's suggestion to "use the shared predicate, not a
# fifth private copy" is not implementable as written for them without
# rewriting each awk program to take the pattern through `-v`. That is a
# change to watcher-critical code with no defect behind it, so it is NOT
# made here. What this buys is that the NEXT bash consumer has somewhere to
# call, and that the rule and its provenance are written down once.
#
# The pattern is anchored and literal on purpose: an unanchored match would
# drop any window whose name merely CONTAINS a bullet, which is a
# permissive-default arm pointing at the population this gate must not
# silently shrink.
bk_is_transient_window_name() {
    case "${1-}" in
        •*) return 0 ;;
        *)  return 1 ;;
    esac
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
#
# `obligations/` (your-org/nexus-code#845) is excluded for BOTH reasons at
# once, and the exclusion is a ruling rather than an omission:
#   * it is audit trail — an obligation record is the evidence of who owed
#     what to whom and how it was discharged, which is precisely what was
#     missing when `sk911` was retired mid-obligation;
#   * it is not window-keyed in the sense this manifest means. Each record
#     names TWO windows, so pruning "the retired window's" records would
#     also delete the counterpart's view of the same edge.
# Staleness is handled where it belongs, in the LIVENESS predicate rather
# than by deletion: `obl_state` reports `void-creditor-absent` for an edge
# whose creditor is no longer in tmux, so retiring a creditor releases its
# debtor automatically and the record survives to say why.
BK_RETIRE_SURFACES=(
    "file:user-prompt/{w}"
    "file:machine-submit/{w}"
    "file:heartbeat/{w}.json"
    "file:pane-change/{w}"
    # {s} (your-org/nexus-code#941, sk897): spawn-worker WRITES this cache
    # under the window KEY, so a {w} template pruned a name the writer never
    # used. Identical to the footgun-seen mismatch one entry down — and this
    # one was CERTIFIED SOUND by the exemption note above until sk897 checked
    # it, which is the worse failure: prose that ends the next reader's
    # investigation rather than merely failing to start it.
    "file:spawn-prompts/{s}.txt"
    "file:worker-health/{w}.json"
    "file:bg-backoff/{w}"
    "file:bg-firstseen/{w}"
    "file:windows/{s}.json"
    "file:skeptic/pending/{s}"
    "dir:skeptic/{s}"
    "prefix:decisions/{w}."
    # {s}, not {w} (your-org/nexus-code#941): the hook WRITES this sentinel
    # under the window KEY, so pruning by the raw name missed it entirely and
    # bk_state_refs_window then reported nothing — `ng retire-window`
    # announced a complete teardown over state it had not touched. A writer
    # and a reader disagreeing about the key is this issue's whole class.
    "prefix:footgun-seen/{s}."
    "tsv:idle-state.tsv"
    "tsv:engagement-log.tsv"
    "tsv:operator-engaged.tsv"
    "tsv:over-limit-state.tsv"
    "tsv:machine-input.tsv"
    # your-org/nexus-code#1101 (skeptic F2/F3). `ng retire-window` DELETES
    # `heartbeat/{w}.json`, which is where the orphan-async loop reads the
    # authoritative wait list from — and it did not prune the loop's own row, so
    # retiring a window through the canonical verb left a row whose wait list
    # could only fall back to `pane-state.sh`'s 80-char capped display string.
    # That gated `#1101`'s terminating conjunction CLOSED in exactly the
    # configuration operators are steered toward. Demonstrated with heartbeat
    # presence as the only variable:
    #   heartbeat present -> row DROPPED, window-close reason=pane-vanished-unlogged
    #   heartbeat deleted -> row HELD  ("the declared wait list is TRUNCATED")
    # Both surfaces are pure watcher bookkeeping for the window being retired —
    # no audit value, unlike the heartbeat itself — so pruning them is right.
    "tsv:orphan-async-state.tsv"
    "file:orphan-async-woken/{s}"
)

# bk_retire_surface_covers <window> <relpath>
#
# Does the MANIFEST name this state-dir-relative path for this window? Public
# because two callers need the same answer and a second implementation is how
# a reader and a writer drift (your-org/nexus-code#941).
bk_retire_surface_covers() {
    local window="$1" rel="$2" entry kind path
    for entry in "${BK_RETIRE_SURFACES[@]}"; do
        kind=$(bk_retire_surface_kind "$entry")
        path=$(bk_retire_surface_path "$entry" "$window")
        case "$kind" in
            file|dir|tsv) [[ "$rel" == "$path" ]] && return 0 ;;
            prefix)       [[ "$rel" == "$path"* ]] && return 0 ;;
        esac
    done
    return 1
}

# bk_state_refs_unmanifested <state-dir> <window>
#
# THE VERIFICATION MUST NOT SHARE THE PRUNER'S ENUMERATION — that is the whole
# reason this function exists (your-org/nexus-code#1101, skeptic F3).
#
# `bk_state_refs_window` iterates BK_RETIRE_SURFACES, exactly as
# `bk_prune_window_state` does. That coupling is deliberate and it is right for
# the question it answers — "did the prune of the surfaces I know about
# succeed" — and it is documented as such. But it makes the check BLIND TO WHAT
# THE MANIFEST OMITS: a surface not in the array is neither pruned nor
# reported, and `ng retire-window` then prints `no state surface references it
# (N surfaces checked)` while state that names the window is still on disk.
# That is verbatim the failure the `#941` comment inside this file warns
# against — "announces a complete teardown over state it did not touch" — and
# the array is a HAND-MAINTAINED enumeration, so the gap reopens every time a
# new surface is added by someone who does not know this list exists.
#
# It is the cross-check that agrees with itself: two answers computed from one
# enumeration confirm each other and neither describes the state dir.
#
# MEASURED before writing this, because "the manifest might be incomplete" is a
# worry and a count is a finding. An independent scan over the live state dir
# (12,379 entries, 47 top-level directories) for five real windows found SIX
# distinct families the 18-entry manifest does not name:
#
#     async-run/{w}                    4 of the 5 windows
#     orphan-async-state.tsv           the F2 finding
#     paste-verdicts/{w}.<epoch>       a prefix family
#     pending-tool/{w}.json
#     pending-decisions-emit-state.tsv
#     prompts/{w}.md
#
# So adding the two entries above fixes two instances of a class with at least
# six members — and six is a LOWER bound, because this scan itself keys on
# basename and TSV first column, so a surface keyed any other way is invisible
# to it too.
#
# WHY THIS REPORTS AND NEVER DELETES. Pruning must stay an explicit list:
# deletion is irreversible and `rm -rf` on a path nobody classified is a worse
# failure than the one being fixed. Four of the six families above have real
# audit value (`async-run/` holds retained exit statuses, `paste-verdicts/` the
# delivery record, `prompts/` the spawn brief) and it is NOT obvious they should
# be destroyed at retirement. So the polarity is split, and that split is the
# design: PRUNE from a list, VERIFY from a scan. An unknown surface then becomes
# a loud "this still names the window and I do not know what it is" rather than
# silence — fail-closed on the reporting side, fail-safe on the deleting side.
#
# Prints `unmanifested<TAB><relpath>` per hit, one per line. Cost measured at
# ~0.5 s against the live state dir; `retire-window` runs once per window.
bk_state_refs_unmanifested() {
    local state_dir="$1" window="$2" key rel f base
    [[ -n "$state_dir" && -n "$window" && -d "$state_dir" ]] || return 0
    key=$(wk_encode "$window")
    # THE KEY SHAPE IS A TOKEN BOUNDARY, NOT A PREFIX (skeptic G1 — CONFIRMED).
    #
    # The first version matched a basename that IS the window/key or BEGINS
    # `<key>.`, and carried a caveat reading "six is a lower bound, because this
    # scan keys on basename and TSV first column". **That caveat was drawn on the
    # wrong axis**: it described THIS FUNCTION'S key shapes, not the state dir, so
    # it could not tell a reader how much was missing — and the clean-branch
    # sentence it licensed ("a manifest-INDEPENDENT scan found no other
    # reference") was a claim about two key shapes rather than about state.
    #
    # Two more families were live and invisible to BOTH the manifest and that
    # scan, because the window sits in the MIDDLE of the basename or behind a
    # leading dot:
    #
    #   obligations/<debtor>__<window>__<kind>.rec
    #   skeptic/pending/.<key>.ledger  /  .<key>.cleared-rationale
    #
    # The second is the one to internalise: `file:skeptic/pending/{s}` IS in the
    # manifest, so this family sits DIRECTLY BESIDE a named sibling — the
    # arrangement most likely to stop a reader looking further.
    #
    # So the key is matched as a TOKEN bounded by start/end or `.`/`_`, which is
    # every delimiter these writers actually use. `-` is deliberately NOT a
    # delimiter: window names contain it, so treating it as one would report
    # `procmatch-sk`'s state when asked about `procmatch` — a false positive
    # ACROSS WINDOWS, the one direction a report must not have.
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        base="${rel##*/}"
        # `find` narrowed to substrings; this turns a substring into an identity.
        [[ "$base" =~ (^|[._])"$key"([._]|$) || "$base" =~ (^|[._])"$window"([._]|$) ]] || continue
        bk_retire_surface_covers "$window" "$rel" && continue
        printf 'unmanifested\t%s\n' "$rel"
    done < <(find "$state_dir" -mindepth 1 \
                  \( -name "*$key*" -o -name "*$window*" \) \
                  -printf '%P\n' 2>/dev/null | sort -u)
    # TSV files at the top level whose FIRST COLUMN names the window. Depth 1
    # only: every window-keyed ledger in this state dir lives there, and an
    # unbounded content scan would report the append-only audit logs, which
    # SHOULD keep naming the window.
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        bk_retire_surface_covers "$window" "$f" && continue
        ( export _BK_W="$window"; awk -F'\t' 'BEGIN { w = ENVIRON["_BK_W"] } $1 == w { found = 1 } END { exit(found ? 0 : 1) }' \
            "$state_dir/$f" 2>/dev/null ) || continue
        printf 'unmanifested	%s	(tsv row)
' "$f"
    done < <(find "$state_dir" -maxdepth 1 -name '*.tsv' -printf '%P\n' 2>/dev/null | sort -u)
    return 0
}

# bk_retire_surface_path <template> <window>
# Expand one manifest template's path part for <window>.
bk_retire_surface_path() {
    # `{s}` is the INJECTIVE key (your-org/nexus-code#941). It used to be the
    # lossy sanitiser, which made this function name another window's state:
    # pruning `a.b` deleted `a_b`'s provenance, require-gate and channel dir.
    local tmpl="$1" window="$2" safe; safe=$(wk_encode "$2")
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
    local state_dir="$1" window="$2" entry kind path p legacy
    # your-org/nexus-code#941 — a surface written under the OLD lossy key is
    # NOT pruned (bk_prune_window_state deliberately never deletes a legacy
    # key, because that key cannot be attributed to one window). It must
    # therefore be REPORTED, or `ng retire-window` announces a complete
    # teardown over state it did not touch. Loud and incomplete beats silent
    # and wrong. Skipped entirely for a name whose keys coincide, which is
    # every name in use.
    if declare -F wk_needs_encoding >/dev/null 2>&1 && wk_needs_encoding "$window"; then
        legacy=$(wk_legacy_key "$window")
        for entry in "${BK_RETIRE_SURFACES[@]}"; do
            kind=$(bk_retire_surface_kind "$entry")
            path=$(bk_retire_surface_path "$entry" "$window")
            # Only the {s}-templated surfaces have a legacy spelling; a {w}
            # template already carries the raw name and never moved.
            [[ "$entry" == *"{s}"* ]] || continue
            path="${path//$(wk_encode "$window")/$legacy}"
            case "$kind" in
                file) [[ -e "$state_dir/$path" ]] && printf 'legacy-file\t%s\n' "$path" ;;
                dir)  [[ -d "$state_dir/$path" ]] && printf 'legacy-dir\t%s\n'  "$path" ;;
            esac
        done
    fi
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
                   && ( export _BK_W="$window"; awk -F'\t' 'BEGIN { w = ENVIRON["_BK_W"] } $1 == w { found = 1 } END { exit(found ? 0 : 1) }' \
                        "$state_dir/$path" 2>/dev/null ); then
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
            dir)
                # A SKEPTIC CHANNEL IS ARCHIVED, NOT DESTROYED (your-org/nexus-code#1434,
                # #1270 residual A). `rm -rf` made skeptic/ a corpus of survivors —
                # 10 of 10 retirements in one afternoon destroyed a channel, two of
                # them the evidence a still-open survey cited — and it made `DONE
                # absent` encode two states that want opposite actions ("never
                # written" and "written then pruned"). A move to the sibling
                # `.archive/` keeps the record readable and the retired key CLEAR:
                # the channel dir no longer exists at its live path, so every
                # live-path reader (await, status, the idle probe) sees exactly
                # what it saw after the rm. Any other `dir:` surface keeps `rm -rf`.
                if [[ -d "$state_dir/$path" ]]; then
                    case "$path" in
                        skeptic/*)
                            # The FALLBACK is the destructive path this surface was
                            # filed to end (#1434), so it is never silent: if the
                            # archive cannot be created or the move fails, say so on
                            # stderr BEFORE the rm, naming what is being destroyed.
                            if mkdir -p "$state_dir/skeptic/.archive" 2>/dev/null \
                               && mv -f "$state_dir/$path" "$state_dir/skeptic/.archive/$(basename -- "$path").retired-$(date +%Y-%m-%dT%H%M%S)" 2>/dev/null; then
                                :
                            else
                                printf 'bookkeeping: WARNING — could not ARCHIVE skeptic channel %s under %s/skeptic/.archive/ (mkdir or mv failed); falling back to rm -rf, so this channel'"'"'s records are DESTROYED rather than kept (your-org/nexus-code#1434)\n' \
                                    "$path" "$state_dir" >&2
                                rm -rf "$state_dir/$path" 2>/dev/null || true
                            fi ;;
                        *)  rm -rf "$state_dir/$path" 2>/dev/null || true ;;
                    esac
                fi ;;
            prefix)
                for p in "$state_dir/$path"*; do
                    [[ -e "$p" ]] || continue
                    rm -rf "$p" 2>/dev/null || true
                done ;;
            tsv)
                [[ -f "$state_dir/$path" ]] || continue
                tmp="$state_dir/$path.retire.$$"
                # ENVIRON[], not `awk -v w=` (your-org/nexus-code#1419): `-v`
                # ESCAPE-PROCESSES its value, so a window name with a backslash
                # pruned a DIFFERENT window's row and left the target's — and the
                # two verifiers above shared the transform, so they agreed with
                # the wrong answer in both directions. All three sites together.
                # `export` in a subshell rather than an inline `VAR=… awk` prefix
                # on the pipeline element: the inline form takes the element out
                # of early-exit-readers.sh's view (#1415).
                if ( export _BK_W="$window"; awk -F'\t' 'BEGIN { w = ENVIRON["_BK_W"] } $1 != w' "$state_dir/$path" > "$tmp" 2>/dev/null ); then
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
