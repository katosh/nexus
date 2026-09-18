#!/usr/bin/env bash
# `ng` verbs must accept flags in any position — your-org/nexus-code#906 C,
# closing the class `#858 B` was filed against.
#
# THE DEFECT. `#858 B` reported that `ng comment --repo <owner/name> <issue>`
# fails and blames the REPO: `ng: unknown flag: your-org/nexus-code`, which
# reads as "that repo is not recognised" rather than "that argument is in the
# wrong position". `#900` fixed `cmd_reply`/`cmd_comment`. `#906 C` found
# `close` and `comment-edit` emitting the byte-identical diagnostic.
#
# WHY THIS SUITE ENUMERATES FROM THE MECHANISM. Fixing the two verbs that were
# reported is what produced `#906 C` in the first place — `#858 B` named
# `comment`, `#900` fixed `comment`, and thirteen siblings kept the defect.
# Enumerated from the SHAPE rather than from the reports, `monitor/ng` had
# **15** verbs carrying it, not two:
#
#     local x="${1:-}"; shift        # the positional is taken unconditionally,
#     while (( $# > 0 )); do         # even when it is a flag …
#         case "$1" in
#             --repo) …;;
#             *) die "unknown flag: $1" ;;   # … so the flag's VALUE lands here
#
# The remedy is the one `#858 B` itself ranked first and this file already
# implemented four times (`cmd_react`, `cmd_react_issue`, `cmd_process`,
# `cmd_process_issue`): capture the positional INSIDE the loop, so flags and
# positionals interleave. That deletes the failure instead of rewording it.
# No arity table is needed — each flag arm already consumes its own value, so
# any bare token still standing when `*)` is reached IS a positional.
#
# Part A is a structural lint (the class), Part B is behavioural (that the
# class property delivers the user-visible outcome). Neither alone is enough:
# a lint can pass over a verb whose shape changed but whose behaviour did not,
# and probing a handful of verbs says nothing about the sixteenth.
#
# Run: bash monitor/watcher/test-ng-flag-order.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_SRC="$_test_dir/../ng"

# Ledger-backed, so a verdict raised in a subshell is not lost.
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

WORK=$(mktemp -d -t nexus-906c-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

command -v gawk >/dev/null 2>&1 || { th_skip "gawk absent" "the lint uses gawk's match(...,arr)"; th_summary_and_exit; }

# The lint. A verb is in the OLD shape when it captures its positional from
# `$1` BEFORE its argument loop AND its loop's catch-all arm dies calling a
# bare token an unknown flag. Both halves are load-bearing: the capture alone
# is harmless if the catch-all takes positionals, and a catch-all alone is
# fine if nothing was pre-captured.
_old_shape_verbs() {
    gawk '
      match($0,/^cmd_([a-z0-9_]+)\(\) \{/,f){fn="cmd_" f[1]; inf=1; pre=0; loop=0; bad=0; in_catch=0}
      # your-org/nexus-code#906 R2. The anchor used to require `local` and the
      # assignment on ONE line. `cmd_wrap_up` — the instance that motivated
      # this whole guard — declares `local issue=""` on one line and assigns
      # `issue="${1:-}"` on another, so the lint was blind to the very shape
      # it exists to catch. A guard that misses its own motivating case will
      # miss the next one identically. Match the ASSIGNMENT, `local` or not,
      # and either positional slot (wrap-up binds both).
      inf && !loop && /(local +)?[a-z_]+="\$\{[12]:-\}"/ { pre=1 }
      inf && /while \(\( \$# > 0 \)\)/ { loop=1 }
      inf && loop && /^[[:space:]]*\*\)[[:space:]]*die "[^"]*unknown flag/ { bad=1 }
      inf && loop && /^[[:space:]]*\*\)[[:space:]]*(usage|echo)[^\n]*unknown/ { bad=1 }
      # your-org/nexus-code#906 R-a. THE FIX DELETED THE STRING THIS LINT KEYED
      # ON. Both predicates above match `die "… unknown flag"` — the wording the
      # conversion REMOVES — so after the repair the lint could only witness a
      # WHOLESALE undo, never the realistic failure: one verb drifting back
      # while the catch-all keeps its new, correct shape. A partial regression
      # of `ng skeptic resolve` ran 21/21 green.
      #
      # That is the subject of this very PR landing inside a fix FOR it: a guard
      # measuring the presence of a construct the repair removes can only see
      # the past. So a catch-all that CAPTURES A POSITIONAL also counts —
      # because a pre-loop capture is wrong whichever way the catch-all is
      # written, and the pre-loop capture is the defect.
      inf && loop && /^[[:space:]]*\*\)/ { in_catch=1 }
      in_catch && /_die_positional|if \[\[ -z "\$[a-z_]+" \]\]; then [a-z_]+="\$1"/ { bad=1; in_catch=0 }
      in_catch && /;;/ { in_catch=0 }
      inf && /^\}/ { if (pre && bad) print fn; inf=0 }
    ' "$1"
}

# ---- WHAT THIS GUARD DOES **NOT** COVER, and as of when ------------------
#
# Declared because an UNDECLARED EXCLUSION is the defect even when the excluded
# set is currently clean. A future reader otherwise sees a guard walking a
# handful of scripts with no way to learn that others were considered, on what
# basis, or when anyone last looked.
#
# THE PREVIOUS VERSION OF THIS COMMENT WAS WRONG TWICE, and both errors are the
# reason it is now DERIVED rather than typed (your-org/nexus-code#906 N-series):
#
#   * it said the delegated set was **9**; the derivation returns **8**. A
#     boundary comment that misstates its own count sends the next reader
#     somewhere false with confidence — worse than no comment, which is the
#     opposite of why it was added.
#   * it said the 36 excluded scripts were out "because they are not part of
#     the `ng` argument surface". That was FALSE for **9 of them** —
#     `lit.sh`, `paste-followup.sh`, `guards-for-diff.sh`, `declare-wait.sh`,
#     `declare-no-wait.sh`, `reports-roll.sh`, `write-probe.sh`,
#     `user-pat.sh`, `ci-head-attempts.sh` are ALL reachable as `ng <verb>`,
#     through the ONE-LINE `_facade` form the `"$_script_dir/…"` derivation
#     never saw. They were excluded by a blind spot, described as a decision.
#
# IN the population: `monitor/ng` plus every script `ng` DELEGATES A VERB TO,
# discovered at runtime in BOTH of the two forms `ng` uses —
# `"$_script_dir/<name>.sh"` (8) and the one-line `_facade <name>.sh` (14,
# three of them shared with the first form) — **19** files as of the date
# below, and `_ng_surface_scripts` prints them. That boundary is #906 F2's:
# the population is the verbs `ng` EXPOSES, not the lines `monitor/ng`
# CONTAINS. `sk911b`'s "11 `_facade`-form scripts" is this set's `_facade`
# half minus the three already reached by the first form; the two numbers were
# never in conflict, they were two slices nobody had named.
#
# OUT of the population: flag-parsing scripts under `monitor/` that `ng`
# cannot reach. Measured 2026-08-14 at e9b2d2d: **44** scripts match
# `^\s*--flag)`, **17** of them are in the surface above, leaving **27** OUT —
# bootstrap-*, boot-recover.sh, ci-attempt-history.sh, claude-loop.sh,
# jupyter-up.sh, remote-up.sh, worker-health.sh and so on. NONE of the 27 is
# an `ng` verb, which is the property the old comment asserted and did not
# have.
#
# "Clean today" is a POINT-IN-TIME FACT. Nothing here asserts the excluded set
# is clean now — only that it is outside scope. Re-measure with:
#     for f in monitor/*.sh; do grep -qE '^[[:space:]]*--[a-zA-Z0-9|_-]+\)' "$f" \
#         && basename "$f"; done | sort > /tmp/flagparse
#     # then: comm -23 /tmp/flagparse <(…_ng_surface_scripts | sort)
#
# ---- THE NUMERIC FLOORS THAT REMAIN, declared and SELF-CHECKED -------------
#
# your-org/nexus-code#943's class: a WRITTEN-DOWN number standing in for a
# MEASURED population. A floor certifies the walk that produced it and tolerates
# everything down to itself, silently. B-REACH's `>= 25` was one of these — it
# certified a walk of 40 and would have accepted losing the whole 15-verb
# `skeptic` family, the exact population this file's N1 fix exists to reach —
# and it is now DERIVED (see B-REACH-POP).
#
# THE FIRST VERSION OF THIS DECLARATION WAS ITSELF THE DEFECT IT DESCRIBES: it
# enumerated ONE file, by hand, and this PR authored TWO guards. The four bounds
# in `test-ng-usage-flag-coverage.sh` went unlisted — including
# `DCHECKED >= 40` against a true **89**, the widest slack of any bound in
# either file, which tolerated dropping `request-channel.sh` and
# `pane-state.sh` (42 % of the flag population, `#906 R1`'s own script among
# them) while printing that the walk had happened. A declaration whose scope is
# a hand-picked file is a floor wearing prose.
#
# So the inventory below is CHECKED, by the assertion at the foot of this file:
# the bounded names are grepped out of this file and compared to the block
# between the markers. Add a bound without declaring it and the guard fails.
# The sibling file carries the same block and now declares NONE — all four of
# its floors are derived.
#
# NOT in scope, deliberately: `<=` bounds on a DIAGNOSTIC (`_C_LEN <= 260`,
# `_EX_BYTES <= 120`) are the property itself — "do not swamp the reader" — not
# a number standing in for a measured population. A floor proxies for a
# measurement; a cap IS the measurement.
#
# SLACK IS EMITTED AT RUNTIME, NOT FROZEN HERE (your-org/nexus-code#911, from
# sk911b's finding). The inventory answered "which bounds exist" but not "how
# much room does each have", and a work-list without slack cannot be ranked:
# a floor with zero slack is a PIN wearing the wrong syntax — it bites today
# and goes slack by one the moment its population grows — while a floor with
# ten would tolerate losing a fifth of the dispatcher without a word.
#
# The measured column deliberately does NOT live in this comment. Every one of
# these bounds already prints its true value in its own PASS line, so a number
# copied up here would be a measurement frozen in prose beside the assertion
# that recomputes it — the exact shape this file exists to catch, re-created in
# the remedy. Each PASS line now reads `floor N slack M` instead, computed in
# the same run that computes the true value, so it can never go stale and no
# assertion is needed to police it.
#
# <!-- BEGIN BOUND-INVENTORY -->
#   _DELEG_FNS   A1b — cmd_* functions inspected across the surface scripts
#   _SURFACE_N   A1b — scripts in the ng argument surface
#   VERB_TOTAL   A2  — cmd_* functions in monitor/ng
#   VERB_COUNT   B   — verbs on the top-level dispatcher
#   _B_DOC       B-DOC — sub-verbs the _verb_index heredoc documents
#   _D_FILES     D1  — files defining _arg_excerpt
#   _ex_checked  C-DRIFT — file/probe pairs actually compared
#   _E_PROBES    E1  — live oversized-token probes that actually ran
# <!-- END BOUND-INVENTORY -->
#
# `${#reason} -lt 40` in the sibling guard is NOT in this inventory, and the
# omission is a decision rather than a silence: it bounds a STRING (a
# drift-manifest row's minimum reason length), not a walked population. Stated
# because an undeclared exclusion reads exactly like a blind spot.
#
# Each is a non-vacuity anchor on a DIFFERENT population from B-REACH's, and
# each is derivable by the same move — reconcile against a second,
# independently-written enumeration rather than against a constant. None is
# converted here: this PR is one step from merge with CI down, and converting
# seven anchors at once trades a reviewed change for an unreviewed one. They
# belong to `#943`, and this block is that issue's work-list. `_B_DOC` is the
# one to derive first: B-REACH-POP leans on B-DOC as its terminus, so a floor
# there is load-bearing for an assertion that deliberately has none.

# Slack for a population floor, derived in the run that measures the true
# value. `floor 19 slack 0` says "this is a pin"; `floor 40 slack 10` says
# "this would tolerate losing a fifth of the dispatcher". See the inventory
# block above for why the number is computed rather than written down.
_slack() {   # <true> <floor> → "floor N slack M"
    printf 'floor %d slack %d' "$2" "$(( $1 - $2 ))"
}

# ===========================================================================
# PART A — the lint, and proof that it can see the thing it looks for.
# ===========================================================================
echo '=== PART A: no ng verb captures its positional ahead of its flag loop ==='

# A0. POSITIVE CONTROL FIRST, deliberately. Every assertion below this line is
#     an ABSENCE, and an absence is what a broken probe reports for free. The
#     fixture is the exact pre-#906 shape; if the lint cannot see it there,
#     the zero it reports against the real file means nothing.
OLD_FIX="$WORK/old-shape.sh"
cat > "$OLD_FIX" <<'FIXTURE'
cmd_planted_old() {
    local issue="${1:-}"; shift || true
    [[ -n "$issue" ]] || die "usage: ng planted-old <issue> [--repo <owner/name>]"
    local repo_arg=""
    while (( $# > 0 )); do
        case "$1" in
            --repo) repo_arg="${2:-}"; shift 2 ;;
            *) die "unknown flag: $1" ;;
        esac
    done
}
FIXTURE
assert_eq "A0 CONTROL the lint detects a planted old-shape verb" \
    "$(_old_shape_verbs "$OLD_FIX")" "cmd_planted_old"

# A0b. NEGATIVE CONTROL. The interleaving shape must NOT be flagged, or the
#      lint would simply reject everything and its zero would be vacuous the
#      other way.
NEW_FIX="$WORK/new-shape.sh"
cat > "$NEW_FIX" <<'FIXTURE'
cmd_planted_new() {
    local issue="" repo_arg=""
    while (( $# > 0 )); do
        case "$1" in
            --repo) repo_arg="${2:-}"; shift 2 ;;
            --*) die "unknown flag: $1" ;;
            *)  if [[ -z "$issue" ]]; then issue="$1"
                else die "unexpected extra positional: $1"; fi
                shift ;;
        esac
    done
    [[ -n "$issue" ]] || die "usage: ng planted-new <issue> [--repo <owner/name>]"
}
FIXTURE
assert_empty "A0b CONTROL the interleaving shape is NOT flagged" \
    "$(_old_shape_verbs "$NEW_FIX")"

# A1. The property itself — over monitor/ng AND every script it delegates a
# verb to (your-org/nexus-code#906 R1).
#
# The population correction landed on the usage-coverage guard and NOT here,
# which left ten functions in skeptic-channel.sh and request-channel.sh as
# live, unfixed instances — invisible to BOTH halves of this guard. One of
# them was `ng skeptic resolve`, the verb that motivated the correction in the
# first place. That is #906 C's own shape recurring: a fix applied where it
# was named rather than where the mechanism reaches.
#
# TWO delegation forms, and the first cut of this derivation saw one
# (your-org/nexus-code#906 N2). `"$_script_dir/<name>.sh"` is the `cmd_skeptic`
# shape; `_facade <name>.sh "$@"` is the ONE-LINE shape fourteen verbs use, and
# it carries no `$_script_dir` for the regex to anchor on. Reading only the
# first form put `ng lit`, `ng paste-followup`, `ng guards-for-diff` and six
# others outside every part of this file while the comment above called them
# out-of-scope.
_ng_surface_scripts() {
    {   grep -oE '"\$_script_dir/[a-z0-9-]+\.sh"' "$NG_SRC" | sed 's|.*/||; s|"||'
        grep -oE '_facade[[:space:]]+[a-z0-9-]+\.(sh|py)'   "$NG_SRC" | sed 's|.*[[:space:]]||'
    } | sort -u
}
LIVE=$(_old_shape_verbs "$NG_SRC")
while IFS= read -r _ds; do
    _dsp="$(dirname "$NG_SRC")/$_ds"
    [[ -r "$_dsp" ]] || continue
    _found=$(_old_shape_verbs "$_dsp")
    [[ -n "$_found" ]] && LIVE="$LIVE"$'\n'"$(sed "s|^|$_ds |" <<<"$_found")"
done < <(_ng_surface_scripts)
LIVE=$(sed '/^$/d' <<<"$LIVE")
assert_empty "A1 no verb in monitor/ng OR a delegated script is in the old shape" "$LIVE"

# A1b. NON-VACUITY of the extended half: the delegated scan must have walked
# real files, or A1's silence is about an empty set.
_DELEG_FNS=0
while IFS= read -r _ds; do
    _dsp="$(dirname "$NG_SRC")/$_ds"
    # Count what the LINT INSPECTS — `cmd_*` functions — not every function
    # in the file (your-org/nexus-code#906 R-d). The first cut counted all of
    # them and vouched for coverage with 144 when the lint had inspected 36.
    # A non-vacuity check that certifies with an inflated number is worse than
    # none: it is a green that actively misleads about its own reach.
    [[ -r "$_dsp" ]] && _DELEG_FNS=$(( _DELEG_FNS + $(grep -cE '^cmd_[a-z0-9_]+\(\) \{' "$_dsp") ))
done < <(_ng_surface_scripts)
_SURFACE_N=$(_ng_surface_scripts | wc -l)
if (( _DELEG_FNS >= 39 && _SURFACE_N >= 19 )); then
    pass "A1b the delegated scripts were really walked ($_SURFACE_N surface scripts [$(_slack "$_SURFACE_N" 19)], $_DELEG_FNS cmd_* functions INSPECTED by the lint [$(_slack "$_DELEG_FNS" 39)])"
else
    fail "A1b only $_DELEG_FNS cmd_* functions across $_SURFACE_N surface scripts — the scan is broken, not the files"
fi

# A2. NON-VACUITY of the population. A lint that parses no verbs at all also
#     reports zero. Count the verbs it actually walked and sanity-check it
#     against a known total.
VERB_TOTAL=$(grep -cE '^cmd_[a-z0-9_]+\(\) \{' "$NG_SRC")
if (( VERB_TOTAL >= 40 )); then
    pass "A2 the lint walked a plausible verb population ($VERB_TOTAL cmd_* functions [$(_slack "$VERB_TOTAL" 40)])"
else
    fail "A2 only $VERB_TOTAL cmd_* functions found in ng — the scan is broken, not the file"
fi

# ===========================================================================
# PART B — behaviour, through a hermetic gh. The lint is about shape; this is
# about what a caller actually sees.
# ===========================================================================
echo '=== PART B: flag-before-positional produces no wrong-token diagnostic ==='

setup_fake_nexus "$WORK/nexus" --allow-default --repo 'your-org/example-nexus'
NG="$FAKE_NEXUS/monitor/ng"
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)                  printf 'your-org/example-nexus' ;;
    github.user_login)            printf 'test-user' ;;
    github.overview_issue_number) printf '1' ;;
    *) [[ $# -ge 2 ]] && { printf '%s' "$2"; exit 0; }; exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

STUB_DIR="$WORK/bin"; CAPTURE="$WORK/gh-calls.txt"
make_gh_stub "$STUB_DIR/gh" "$CAPTURE" <<'CASES'
    *)  printf '%s' '{"html_url":"https://mock.example/x","body":"b","id":1,"state":"open","updated_at":"t"}' ;;
CASES

NEUTRAL="$WORK/neutral"; mkdir -p "$NEUTRAL"
NG_BIN=""
run_ng() {
    local _o="$1" _e="$2" _r="$3"; shift 3
    local ot et
    ot=$(mktemp); et=$(mktemp)
    ( cd "$NEUTRAL" && run_hermetic NEXUS_ROOT="$FAKE_NEXUS" NEXUS_STATE_DIR="$WORK/state" \
        PATH="$STUB_DIR:$PATH" -- "${NG_BIN:-$NG}" "$@" </dev/null ) >"$ot" 2>"$et"
    local rc=$?
    printf -v "$_o" '%s' "$(<"$ot")"; printf -v "$_e" '%s' "$(<"$et")"; printf -v "$_r" '%s' "$rc"
    rm -f "$ot" "$et"
}

# The exact token `#858 B` saw blamed. A verb that names THIS as an unknown
# flag has the defect, whatever else it goes on to do — and the signature is
# general: in the old shape the flag lands in the positional slot and its
# VALUE reaches the catch-all, whether or not the verb accepts `--repo` at
# all. (A NEW-shape verb that does not accept it says `unknown flag: --repo`,
# a different string, and is correctly not flagged.)
BAD='zzz-probe-value/zzz'
# TWO positionals, with distinctive values, and a discriminator that flags the
# error naming ANY of the three tokens the caller supplied — not just the
# flag's value (your-org/nexus-code#906 F1).
#
# The first cut probed one positional and matched only `unknown flag: $BAD`,
# because in the fifteen converted verbs the flag lands in the positional slot
# and its VALUE reaches the catch-all. `cmd_wrap_up` fails the other way round:
# it takes TWO positionals and pre-bound both, so `ng wrap-up --repo <r> 906
# <report>` reported the ISSUE NUMBER — `unknown flag: 906`. A probe shaped
# around one mechanism cannot see the other, which is how the highest-traffic
# hand-off verb on the board sat outside a class derived from its own shape.
POS1='zzzpositionalone'
POS2='zzzpositionaltwo'
#
# THE DISCRIMINATOR MUST NOT KEY ON A STRING THE REPAIR DELETES
# (your-org/nexus-code#906 N1). This function used to match `unknown flag: <tok>`
# and nothing else — the pre-#906 wording. R1's diagnostic fix REPLACES that
# wording with `unexpected POSITIONAL argument '<tok>'`, and the R-c excerpt
# pass added quotes to the flag wording too. So the moment the repair landed,
# every sub-verb carrying it became invisible here: Part B walked the 25 newly
# reached channel sub-verbs and could not fail on any of them. Live
# structurally, dead behaviourally — the coverage number lied.
#
# That is R-a's finding one axis over, and it is this PR's own subject: a guard
# keyed on the presence of a construct the repair removes can only witness the
# past. The property is "the parser REFUSED, naming a token the caller
# supplied", so match every wording that expresses it, old and new. A regression
# that reinstates the pre-loop capture while keeping the new catch-all — the
# realistic partial regression — produces the SECOND form, and the planted
# control below fails without these lines.
_names_a_supplied_token() {   # <stderr>
    local _t
    for _t in "$BAD" "$POS1" "$POS2"; do
        [[ "$1" == *"unknown flag: $_t"*                       ]] && return 0
        [[ "$1" == *"unknown flag: '$_t'"*                     ]] && return 0
        [[ "$1" == *"unexpected POSITIONAL argument $_t"*      ]] && return 0
        [[ "$1" == *"unexpected POSITIONAL argument '$_t'"*     ]] && return 0
        [[ "$1" == *"unexpected extra positional: $_t"*        ]] && return 0
    done
    return 1
}

# THE PROPERTY IS ORDER-INDEPENDENCE, not "never says unknown flag".
#
# Matching the diagnostic alone over-fires: `interactive-sessions`,
# `nexus-identity`, `issue create` and `pr create` take NO positionals, so
# supplying one is invalid in EVERY order and the complaint is correct. A
# probe that flagged them would be measuring the wrong thing and would have to
# be silenced with an exemption list — which is how a guard turns into a list.
#
# So the verb is run BOTH ways and only a DIFFERENCE is a finding: flags-last
# accepted, flags-first rejected, is the defect and nothing else is. That is
# self-normalising — a verb taking no positionals fails both ways and is
# silent here, with no exemption needed.
# BOTH ARITIES, because the probe must fit the verb. Sending two positionals
# to a ONE-positional verb makes both orders fail — the extra positional is
# rejected either way — and the asymmetry that reveals the defect disappears.
# The planted-control assertion below is what caught that; without it this
# sweep would have reported a confident clean sheet while blind to every
# single-positional verb, which is most of them.
_order_sensitive() {   # <ng> <verb...>  → rc0 when flag-first is rejected and flag-last is not
    local ng="$1"; shift
    local -a arities=(1 2) n
    for n in "${arities[@]}"; do
        local -a pos=("$POS1"); (( n == 2 )) && pos=("$POS1" "$POS2")
        NG_BIN="$ng" run_ng sw_o sw_e sw_r "$@" "${pos[@]}" --repo "$BAD"
        local last_bad=0; _names_a_supplied_token "$sw_e" && last_bad=1
        NG_BIN="$ng" run_ng sw_o sw_e sw_r "$@" --repo "$BAD" "${pos[@]}"
        local first_bad=0; _names_a_supplied_token "$sw_e" && first_bad=1
        (( first_bad == 1 && last_bad == 0 )) && return 0
    done
    return 1
}

# THE SWEEP, and why it does not reuse Part A's enumeration.
#
# Part A's lint reads `ng`'s own `case` structure and so rests on three
# spellings: `local X="${1:-}"`, `while (( $# > 0 ))`, and a catch-all whose
# die text contains "unknown flag". A verb spelled differently is invisible to
# it — and that is not hypothetical: the first cut of that regex MISSED
# `cmd_respawn`, whose arm says `respawn: unknown flag`, because the prefix
# defeated the anchor. Enumerating the population from the same structure the
# fix was derived from is precisely the blind spot that let `#858` close
# against two verbs.
#
# So this sweep shares NO assumption with it. The verb list comes from the
# top-level DISPATCHER — the authoritative answer to "what can `ng` be asked
# to do" — and membership is decided by RUNNING each verb, not by reading it.
_dispatch_verbs() {
    local l; l=$(grep -n '# ---- dispatch ----' "$NG_SRC" | tail -1 | cut -d: -f1)
    awk -v s="$l" 'NR>s && match($0,/^        ([a-z][a-z0-9-]*)\)/,m){print m[1]}' "$NG_SRC" | sort -u
}
# Sub-verbs, so the sweep reaches the functions behind a sub-dispatcher.
# DERIVED from each verb's own sub-dispatcher, not from a hand list
# (your-org/nexus-code#906 R-a). The hand list named issue/pr/dashboard and so
# Part B never reached `ng skeptic resolve` or `ng request reply` — the very
# verbs F2 and R1 were about. A list of sub-verbs is one more population
# maintained beside the thing it describes, which is the defect this file
# guards; deriving it means a new sub-verb is probed the day it is added.
#
# TRUNCATION, SECOND INSTANCE — INSIDE THE FUNCTION WRITTEN TO FIX THE FIRST
# (your-org/nexus-code#906 N2). R-a removed a `head -12` from this function that
# silently dropped `resolve`, alphabetically twelfth and the exact verb R1 was
# named for. The BODY ANCHOR was the same defect one line up: `sed -n
# "/^cmd_lit() {/,…"` requires `() {` with exactly one space, and FOURTEEN verbs
# are defined as one-liners — `cmd_lit()              { _facade lit.sh "$@"; }`
# — whose run of spaces defeats it. `ng lit`'s four sub-verbs are the
# demonstrable casualty: never enumerated, never probed.
#
# Worse than a miss, for the ONE one-liner that happens to use a single space
# (`cmd_retire_preflight() { … }`): the range `/^}/` cannot terminate on its own
# line, so `sed` runs on to the NEXT function's closing brace and returns a
# FOREIGN body. A wrong answer, not an empty one.
#
# So the form is decided first, and only then is a body taken.
_subs_of() { printf '%s\n' "$1" | gawk '
    # The dispatch target may be `cmd_x` OR a plain helper: `ng lit`s fourth
    # sub-verb is `setup) _setup_refs; exit 0 ;;`, invisible to a `cmd_`-only
    # anchor. Requiring an identifier keeps `open) globs=(…)` — an arm of an
    # unrelated `case` — out, because an assignment is not a call.
    #
    # TRUNCATION, FOURTH INSTANCE — in the TARGET half, and latent
    # (your-org/nexus-code#989). The arm name has always admitted digits
    # (`[a-z][a-z0-9-]*`) and the DISPATCH TARGET never did (`cmd_[a-z_]+`), so
    # `foo) cmd_v2_foo "$@" ;;` was invisible: the arm matched, the target did
    # not, and the row was dropped in silence. Found by the mutant written to
    # attack the multi-delegate fix below — the fixture named its handlers
    # `cmd_m3_alpha`, the walk returned nothing, and the first reading was that
    # the delegate walk had failed. It had not; this had. Measured on this
    # tree: ZERO live dispatch targets carry a digit, so widening changes no
    # current row — it removes a blind spot rather than fixing a live miss, and
    # the zero is potent (the same probe returns 2 on a digit-bearing fixture).
    match($0,/^[[:space:]]+([a-z][a-z0-9-]*)\)[[:space:]]*(cmd_[a-z0-9_]+|_[a-z0-9_]+)[[:space:]]*("|;|$)/,m) { print m[1] }
' | sort -u; }   # NO head cap: see above.
# THE BODY, taken once and shared. `_subs_for`, the delegate walk and the
# fixture installer all need it, and each deriving it separately is how the
# one-liner/block distinction above came to be got wrong in two of them.
_cmd_body() {   # <verb> → the body of cmd_<verb>, or nothing
    local v="$1" fn def
    fn="cmd_${v//-/_}"
    def=$(grep -m1 -E "^${fn}\(\)[[:space:]]*\{" "$NG_SRC")
    [[ -z "$def" ]] && return 0
    if [[ "$def" == *'}' ]]; then
        printf '%s\n' "$def"                          # one-line definition
    else
        sed -n "/^${fn}()[[:space:]]*{/,/^}/p" "$NG_SRC"
    fi
}

# TRUNCATION, THIRD INSTANCE — and this one was in the DELEGATE, not in the
# sub-verb list (your-org/nexus-code#989 × #1014). The extraction below used to
# end `tgt="${tgt%%$'\n'*}"`: it collected every delegation construct in the
# body and then kept the FIRST. That is exactly right for a verb with one
# delegate and silently wrong for a verb with more, and `#1014` added the first
# multi-delegate verb in the tree:
#
#     cmd_remote() {
#         if [[ "${1:-}" == client-helper ]]; then … "$_script_dir/remote-client-helper.sh" … fi
#         … "$_script_dir/remote-enroll.sh" "$@"
#     }
#
# The intercepted arm is written FIRST because it must be tested first, so the
# first-match rule kept `remote-client-helper.sh` — a script with ONE sub-verb —
# and dropped `remote-enroll.sh` with ELEVEN. Measured at the merge seam:
# B-REACH-POP named all eleven (`carrier-authline enroll enroll-invite
# gc-tokens gen-host-key guard host-fingerprint issue-token list prune-enroll
# revoke`) as UNPROBED. The multi-delegate `cmd_remote` is a legitimate shape;
# the enumerator simply could not walk it.
#
# So the delegate is a LIST, in body order, and every one of them is walked.
# Dedup by first appearance rather than `sort -u`, so body order — which is
# dispatch order — survives into the pairs below.
_delegates_of_body() {   # <body> → each delegated script it routes to, once
    printf '%s\n' "$1" \
        | grep -oE '(_facade[[:space:]]+|\$_script_dir/)[a-z0-9-]+\.(sh|py)' \
        | sed 's|.*[/ ]||' \
        | gawk '!seen[$0]++'
}
_delegates_for() { _delegates_of_body "$(_cmd_body "$1")"; }

# THE PAIRS, because a sub-verb is only half an answer once a verb can have
# more than one delegate. B-REACH-POP reconciles `<script> <sub-verb>` rows
# against what each script's OWN dispatcher declares, so attributing a
# sub-verb to the wrong delegate would satisfy neither direction: the row it
# invents reddens one assertion and the row it omits reddens the other. The
# old `_SUBS_TGT` global could not express this at all — one verb, one script.
#
# `-` in the script column marks an INLINE dispatcher (`cmd_issue`, `cmd_pr`,
# …): probed like any other, never reconciled, because there is no delegated
# script to read arms from.
_subs_pairs_for() {   # <verb> → "<script|-> <sub-verb>" per line
    local v="$1" body out sv tgt
    body=$(_cmd_body "$v")
    [[ -n "$body" ]] || return 0
    out=$(_subs_of "$body")
    # `ng`'s own function may be a THIN DELEGATOR (cmd_skeptic, cmd_request,
    # every `_facade`): it exists, so `body` is non-empty, but it holds no
    # sub-verb arms. The first cut stopped there and returned nothing for
    # exactly the two verbs R1 was about. Fall through to the delegated script
    # whenever the DERIVED LIST is empty, not whenever the function is missing.
    #
    # BOTH HALVES, not one or the other (your-org/nexus-code#989). The natural
    # spelling here is `if inline; then …; return; fi` — and that is a THIRD
    # first-match truncation wearing different clothes: a verb holding an inline
    # arm AND a delegate would have its whole delegated population dropped. The
    # mutant written to attack this fix planted exactly that on `cmd_remote` and
    # the walk fell from 49 delegated rows to 38 — all eleven `remote-enroll.sh`
    # rows gone. It reddened B-REACH-POP by name rather than passing, so the
    # property held; the ENUMERATOR was still wrong, and this is where it was
    # wrong. Measured on this tree: the three inline dispatchers (`dashboard`,
    # `issue`, `pr`) name NO delegate in their bodies, so emitting both halves
    # changes no current row. The zero is potent — the same extractor returns
    # three delegates for `cmd_remote`.
    while IFS= read -r sv; do
        [[ -n "$sv" ]] && printf -- '- %s\n' "$sv"
    done <<<"$out"
    # The `.sh` must be extracted from a DELEGATION construct, not from any
    # mention of a filename in the body — a bare `[a-z-]+\.sh` grep picked a
    # script out of `cmd_nexus_identity`'s prose and enumerated that script's
    # sub-verbs as if they were `ng nexus-identity`'s. (`_delegates_of_body`.)
    while IFS= read -r tgt; do
        [[ -n "$tgt" && -r "$(dirname "$NG_SRC")/$tgt" ]] || continue
        while IFS= read -r sv; do
            [[ -n "$sv" ]] && printf '%s %s\n' "$tgt" "$sv"
        done < <(_subs_of "$(cat "$(dirname "$NG_SRC")/$tgt")")
    done < <(_delegates_of_body "$body")
}
# The sub-verb list is now a PROJECTION of the pairs, not a second walk — the
# two cannot disagree about what was enumerated. `sort -u` because two
# delegates of one verb may legitimately dispatch the same sub-verb, and the
# sweep should probe `ng <verb> <sub>` once.
_subs_for() { _subs_pairs_for "$1" | gawk '{print $2}' | sort -u; }

# THE SECOND ENUMERATION — a different axis, because `_subs_for` cannot audit
# itself (your-org/nexus-code#906 N2). Both truncations above were invisible to
# every assertion in this file precisely because the only enumeration was the
# one that was truncated: an under-count and a correct count are the same green.
#
# This axis reads the DOCUMENTATION surface instead of the code: `_verb_index`,
# the heredoc `ng --help` prints. It shares no regex, no anchor and no file
# region with `_subs_for`, so a parser bug cannot silence both. The
# reconciliation below is one-directional by design — every DOCUMENTED sub-verb
# must be probed; the reverse does not hold, because `skeptic <sub> …` and
# `request <sub> …` are documented as families rather than enumerated.
_subs_documented_for() {   # <verb> → sub-verbs named on `ng --help`'s index
    local v="$1" idx n
    idx=$(sed -n '/^_verb_index() {/,/^}/p' "$NG_SRC")
    n=$(printf '%s\n' "$idx" | gawk -v v="$v" '$1==v{c++} END{print c+0}')
    # A bare word after a verb is a sub-verb only when the line groups
    # alternatives (`pr create|edit|merge|view`) or the verb owns several index
    # lines (`lit search` / `lit add` / `lit status` / `lit setup`). Otherwise
    # it is prose — `mint-jwt  print a bot JWT` would otherwise yield `print`.
    printf '%s\n' "$idx" | gawk -v v="$v" -v n="$n" '
        $1 == v {
            t = $2
            if (t !~ /\|/ && n < 2) next
            k = split(t, parts, /\|/)
            for (i = 1; i <= k; i++) if (parts[i] ~ /^[a-z][a-z0-9-]+$/) print parts[i]
        }' | sort -u
}

_sweep() {   # <ng-binary> <hits-out> [verb …]; prints nothing, writes offenders
    # Output variable names must NOT collide with run_ng's own locals
    # (`_o/_e/_r`): `printf -v "$_e"` would then assign to run_ng's LOCAL and
    # the value would die with the function. Measured — it failed exactly so.
    local ng="$1" out="$2"; shift 2
    local v sv verbs
    verbs=$( (( $# )) && printf '%s\n' "$@" || _dispatch_verbs )
    : > "$out"
    while IFS= read -r v; do
        local subs; subs=$(_subs_for "$v")
        if [[ -n "$subs" ]]; then
            for sv in $subs; do
                _order_sensitive "$ng" "$v" "$sv" && printf 'ng %s %s\n' "$v" "$sv" >> "$out"
            done
        else
            _order_sensitive "$ng" "$v" && printf 'ng %s\n' "$v" >> "$out"
        fi
    done <<<"$verbs"
    return 0
}

# THE FIXTURE MUST BE ABLE TO REACH THE PARSERS IT ENUMERATES
# (your-org/nexus-code#906 N1, second half). `setup_fake_nexus` copies `ng` and
# nothing it delegates to, so every `ng skeptic …` / `ng request …` /
# `ng lit …` probe died at the delegator's own gate —
# `skeptic: <path> not found or not executable` — IDENTICALLY in both orders,
# so `_order_sensitive` saw no asymmetry and reported clean. Measured: that was
# true for all 25 channel sub-verbs while this file counted them as covered.
#
# The set is DERIVED from the same delegate walk the sweep makes
# (`_delegates_for`), never hand-listed — and narrow by construction: only
# scripts a dispatcher verb actually ROUTES TO are installed, which is why
# `retire-preflight.sh` and `spawn-worker.sh` never become live here.
#
# EVERY delegate of a verb, not the first (your-org/nexus-code#989 × #1014).
# This installer read `_SUBS_TGT`, so it inherited the first-match truncation
# `_delegates_of_body` above documents: `remote-enroll.sh` was never copied
# into the fixture, and the eleven sub-verbs behind it would have died at the
# delegator's gate the moment the enumerator learned to name them — B-REACH
# red instead of B-REACH-POP red, the same coverage hole one assertion over.
# Measured on this tree, the generalization installs exactly ONE more script
# (`remote-enroll.sh`) and drops none.
_install_delegated_into_fixture() {
    local v tgt lib changed=1 f
    while IFS= read -r v; do
        while IFS= read -r tgt; do
            [[ -n "$tgt" && -r "$_test_dir/../$tgt" ]] || continue
            # NEVER CLOBBER A FILE `setup_fake_nexus` DELIBERATELY STUBBED
            # (your-org/nexus-code#1339). `mint-token.sh` is BOTH a delegate of
            # a dispatcher verb AND a fixture stub, and this blanket copy
            # cannot tell the two apart: it replaced the helper's
            # `printf fake-installation-token` with the REAL script, which in a
            # fake nexus dies `github.bot_app_id missing` at rc 2. From that
            # line to the end of the file the fixture could not mint.
            #
            # Nothing noticed, because `ng`'s `api()` reached `token()`'s
            # `die` only from inside `GH_TOKEN=$(token)` — so the `exit`
            # terminated the SUBSTITUTION, `GH_TOKEN` was bound EMPTY, and
            # `gh` ran anyway. Measured on this fixture, one variable:
            #
            #   with the subshell-exit defect   rc=0  capture=[api /repos/…]
            #   with the gate hoisted           rc=1  capture=[]
            #
            # i.e. THE TWO `B CONTROL … reaches the API` ASSERTIONS WERE
            # PASSING BECAUSE OF THE DEFECT. Restoring the stub is what makes
            # them assert what they say they assert; weakening the gate would
            # not.
            [[ "$tgt" == "mint-token.sh" ]] && continue
            cp "$_test_dir/../$tgt" "$FAKE_NEXUS/monitor/$tgt"
            chmod +x "$FAKE_NEXUS/monitor/$tgt"
        done < <(_delegates_for "$v")
    done < <(_dispatch_verbs)
    # POSITIVE CONTROL on the exclusion above: the fixture must be able to
    # mint AFTER the installer has run. Without this, a future edit that
    # re-clobbers the stub silently restores the old dependency and the
    # `B CONTROL` assertions go back to passing for the wrong reason.
    local _mt
    _mt=$("$FAKE_NEXUS/monitor/mint-token.sh" 2>/dev/null)
    if [[ -n "$_mt" ]]; then
        pass "B FIXTURE the stub mint-token survives the delegate installer"
    else
        fail "B FIXTURE the delegate installer clobbered the stub mint-token — every B CONTROL below this line would assert an empty-token fallthrough, not a reachable API"
    fi
    # Transitive closure over the libraries those scripts source, to a
    # fixpoint: `request-channel.sh` sources `_channel_lib.sh`, which sources
    # `_fm_lib.sh`. A one-pass copy leaves the second missing and the script
    # emits a sourcing error before it ever parses an argument.
    while (( changed )); do
        changed=0
        for f in "$FAKE_NEXUS"/monitor/*.sh; do
            while IFS= read -r lib; do
                [[ -n "$lib" && -r "$_test_dir/../$lib" && ! -r "$FAKE_NEXUS/monitor/$lib" ]] || continue
                cp "$_test_dir/../$lib" "$FAKE_NEXUS/monitor/$lib"; changed=1
            done < <(grep -oE '(source|\.) +"\$(_script_dir|\{?NEXUS_ROOT\}?/monitor)/[_a-z0-9-]+\.sh"' "$f" \
                       | sed 's|.*/||; s|"||')
        done
    done
}
_install_delegated_into_fixture

NG_BIN="$NG"
VERB_COUNT=$(_dispatch_verbs | wc -l)
if (( VERB_COUNT >= 40 )); then
    pass "B the sweep enumerated a plausible verb population ($VERB_COUNT dispatcher verbs [$(_slack "$VERB_COUNT" 40)])"
else
    fail "B only $VERB_COUNT dispatcher verbs found — the enumeration is broken, not the file"
fi

# B-REACH. Before believing any absence the sweep reports, prove the sweep can
# TALK to what it enumerates (your-org/nexus-code#906 N1). A sub-verb whose
# script is missing from the fixture dies at the delegator's gate in BOTH
# orders — perfectly symmetric, perfectly silent, and counted as covered.
: > "$WORK/unreachable.txt"
_B_SUBS=0; _B_ACTUAL=""
while IFS= read -r _v; do
    # PAIRS, not a sub-verb list beside a single target
    # (your-org/nexus-code#989 × #1014). Attribution used to be `_subs_tgt_for`
    # — ONE script for the whole verb — which cannot describe a verb that
    # routes `client-helper` to one script and everything else to another. The
    # pair carries its own script, so a multi-delegate verb reconciles row by
    # row and neither direction of B-REACH-POP has to be relaxed.
    #
    # The DELEGATED half is the half that can die at a gate; the inline
    # dispatchers (script column `-`) are probed too (they cost nothing and the
    # property is the same) but they could never make this assertion bite, so
    # only the delegated rows are reconciled below.
    while IFS=' ' read -r _tgt _sv; do
        [[ -n "$_sv" ]] || continue
        _B_SUBS=$(( _B_SUBS + 1 ))
        [[ "$_tgt" != '-' ]] && _B_ACTUAL+="$_tgt $_sv"$'\n'
        run_ng rch_o rch_e rch_r "$_v" "$_sv" --repo "$BAD"
        [[ "$rch_e" == *'not found or not executable'* ]] && printf 'ng %s %s\n' "$_v" "$_sv" >> "$WORK/unreachable.txt"
    done < <(_subs_pairs_for "$_v")
done < <(_dispatch_verbs)
assert_empty "B-REACH every sub-verb reaches its own parser, none dies at a delegator gate" "$(<"$WORK/unreachable.txt")"

# B-REACH-POP — the NON-VACUITY OF THE ABOVE, DERIVED (your-org/nexus-code#943).
#
# This was a literal floor: `(( _B_DELEG >= 25 ))`, against a true value of 40.
# So losing the ENTIRE 15-verb `skeptic` family — the exact population N1 was
# filed about — landed precisely on the floor and PASSED, with the coverage
# number sliding `40 of 52` → `25 of 37` uncommented. That is R-d one assertion
# over (144 certifying a walk of 36; here 25 certifying a walk of 40), and
# raising the number only moves the cliff: a floor of 40 is a floor of 25 next
# month.
#
# So the expectation is DERIVED and the assertion is EQUALITY. The expected set
# comes from each delegated script's OWN dispatcher, read by anchoring on the
# `unknown subcommand` catch-all and walking UP to the enclosing `case` — the
# OPPOSITE direction to `_subs_of`'s forward `arm) target` scan, so a bug in
# either enumerator shows up as a disagreement rather than as two matching
# silences. A shrinking population now reddens BY NAME.
_dispatch_arms_of_script() {   # <path> → the sub-verbs this script dispatches
    gawk '
      { line[NR] = $0 }
      /unknown([[:space:]]+[a-z]+)?[[:space:]]+subcommand/ { die_at = NR }
      END {
          if (!die_at) exit 0
          for (i = die_at; i >= 1; i--) if (line[i] ~ /case[[:space:]]+"?\$/) { case_at = i; break }
          if (!case_at) exit 0
          for (i = case_at + 1; i < die_at; i++)
              if (match(line[i], /^[[:space:]]+([a-z][a-z0-9|"-]*)\)/, m)) {
                  n = split(m[1], parts, "|")
                  for (j = 1; j <= n; j++)
                      if (parts[j] ~ /^[a-z][a-z0-9-]*$/) print parts[j]
              }
      }' "$1"
}
_B_EXPECT=""
while IFS= read -r _f; do
    _p="$(dirname "$NG_SRC")/$_f"
    [[ -r "$_p" ]] || continue
    while IFS= read -r _a; do
        [[ -n "$_a" ]] && _B_EXPECT+="$_f $_a"$'\n'
    done < <(_dispatch_arms_of_script "$_p")
done < <(_ng_surface_scripts)
printf '  INFO: B-REACH probed %d sub-verbs; %d delegated rows vs %d the scripts dispatch\n' \
    "$_B_SUBS" "$(printf '%s' "$_B_ACTUAL" | grep -c . )" "$(printf '%s' "$_B_EXPECT" | grep -c . )"
assert_empty "B-REACH-POP no sub-verb a delegated script dispatches went UNPROBED" \
    "$(comm -23 <(printf '%s' "$_B_EXPECT" | sort -u) <(printf '%s' "$_B_ACTUAL" | sort -u))"
assert_empty "B-REACH-POP …and the probe invented none the scripts do not dispatch" \
    "$(comm -13 <(printf '%s' "$_B_EXPECT" | sort -u) <(printf '%s' "$_B_ACTUAL" | sort -u))"
#
# WHERE THE REGRESS TERMINATES, since there is deliberately no floor here.
# Both sides collapsing to empty would satisfy the two assertions above. That
# case is caught by B-DOC below, on a THIRD axis: it requires every sub-verb
# `ng --help` documents to be one the sweep probes, so a probe enumeration that
# collapses reddens there naming `ng lit add/search/setup/status` — measured,
# that is exactly what the N2 mutation produced. The terminus is another
# assertion on an independent axis, not a number.

# B-DOC. The SECOND enumeration, reconciled against the first. Every sub-verb
# `ng --help` advertises must be one the sweep actually probes; a sub-verb the
# code-reading axis cannot see is exactly what `head -12` and the body anchor
# each hid, and neither was visible to any assertion because the only
# enumeration was the broken one.
: > "$WORK/undocumented-gap.txt"
_B_DOC=0
while IFS= read -r _v; do
    _probed=" $(_subs_for "$_v" | tr '\n' ' ')"
    while IFS= read -r _d; do
        [[ -n "$_d" ]] || continue
        _B_DOC=$(( _B_DOC + 1 ))
        [[ "$_probed" == *" $_d "* ]] || printf 'ng %s %s\n' "$_v" "$_d" >> "$WORK/undocumented-gap.txt"
    done < <(_subs_documented_for "$_v")
done < <(_dispatch_verbs)
assert_empty "B-DOC every sub-verb ng --help documents is one the sweep probes" "$(<"$WORK/undocumented-gap.txt")"
if (( _B_DOC >= 16 )); then
    pass "B-DOC …and the documentation axis found sub-verbs to reconcile ($_B_DOC [$(_slack "$_B_DOC" 16)])"
else
    fail "B-DOC only $_B_DOC documented sub-verbs — the second axis is broken, so the line above is vacuous"
fi

_sweep "$NG" "$WORK/sweep-live.txt"
assert_empty "B no verb is ORDER-SENSITIVE (flag-first rejected, flag-last accepted)" "$(<"$WORK/sweep-live.txt")"

# B POSITIVE CONTROL — the sweep must be able to SEE the defect. Without this
# the assertion above is an absence produced by a probe nobody proved works,
# which is the shape this whole PR is about. Plant the pre-#906 shape in a
# copy and require the sweep to name that verb and no other.
PLANTED_NG="$FAKE_NEXUS/monitor/ng-planted"
python3 - "$NG" "$PLANTED_NG" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# The `--repo` arm carries your-org/nexus-code#903's `_need_val` guard, which
# landed on a DIFFERENT axis from #906: #903 guards a flag's VALUE, #906 the
# positional's PLACE. They meet in this literal anchor and nowhere else, so
# this is the one place the two have to be spelled together. The mutant keeps
# the guard and reverts only the placement — the realistic single-PR
# regression — and the sweep's discriminator is behavioural (`_order_sensitive`
# runs the binary), so `_need_val` is inert to the verdict either way.
#
# your-org/nexus-code#924 lands on this same anchor for the same reason —
# it rewrites the `while` HEADER of every argument loop. Three PRs now meet
# in this one literal block, on three different axes (value / placement /
# loop progress), which is why it is spelled out in full rather than
# regex-matched: a fuzzy anchor here would silently plant nothing, and a
# plant that does not apply reports the sweep as blind rather than the
# anchor as stale. The `assert s.count(new) == 1` is what makes that loud.
new = '''    local cid=""
    local repo_arg="" with_meta=0
    _argloop_prev_22=-1; while (( $# > 0 )); do (( $# != _argloop_prev_22 )) || _argloop_stuck "$1"; _argloop_prev_22=$#
        case "$1" in
            --repo) _need_val --repo "$#" "${2:-}"; repo_arg="$2"; shift 2 ;;
            --meta) with_meta=1;       shift   ;;
            --*) die "unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$cid" ]]; then cid="$1"
                else die "unexpected POSITIONAL argument $(_arg_excerpt "$1"). Flags must start with --; positionals are matched in order."; fi
                shift ;;
        esac
    done
    [[ -n "$cid" ]] || die "usage: ng show <comment-id> [--repo <owner/name>] [--meta]"'''
old = '''    local cid="${1:-}"; shift || true
    [[ -n "$cid" ]] || die "usage: ng show <comment-id> [--repo <owner/name>] [--meta]"
    local repo_arg="" with_meta=0
    _argloop_prev_22=-1; while (( $# > 0 )); do (( $# != _argloop_prev_22 )) || _argloop_stuck "$1"; _argloop_prev_22=$#
        case "$1" in
            --repo) _need_val --repo "$#" "${2:-}"; repo_arg="$2"; shift 2 ;;
            --meta) with_meta=1;       shift   ;;
            *) die "unknown flag: $1" ;;
        esac
    done'''
assert s.count(new) == 1, "plant anchor missing/not unique"
open(dst, 'w').write(s.replace(new, old, 1))
PY
chmod +x "$PLANTED_NG"
_sweep "$PLANTED_NG" "$WORK/sweep-planted.txt"
assert_eq "B CONTROL the sweep detects a planted old-shape verb" \
    "$(<"$WORK/sweep-planted.txt")" "ng show"
NG_BIN="$NG"

# B CONTROL, DELEGATED + PARTIAL — the control your-org/nexus-code#906 N1 was
# filed for. The one above plants in `ng` and reverts the arm WHOLESALE, which
# is the regression nobody makes. This one plants in a DELEGATED script and
# reverts only the PRE-LOOP CAPTURE, leaving the repaired catch-all in place —
# the realistic drift, and the one the old discriminator could not see because
# the surviving catch-all no longer says "unknown flag".
#
# It is deliberately the same verb R1 was named for. Restored immediately, and
# the restore is verified: a control that leaves the fixture mutated turns every
# later assertion into a measurement of the mutant.
_CHAN="$FAKE_NEXUS/monitor/skeptic-channel.sh"
cp "$_CHAN" "$WORK/skeptic-channel.orig"
python3 - "$_CHAN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
new = '''cmd_resolve() {
    local task=""
'''
old = '''cmd_resolve() {
    local task="${1:-}"; shift || true
'''
assert s.count(new) == 1, "partial-regression anchor missing/not unique"
open(p, 'w').write(s.replace(new, old, 1))
print("[applied] cmd_resolve pre-loop capture reinstated", file=sys.stderr)
PY
_CHAN_PLANT_RC=$?
_sweep "$NG" "$WORK/sweep-chan.txt" skeptic
cp "$WORK/skeptic-channel.orig" "$_CHAN"
assert_eq "B CONTROL the plant applied (python exited 0)" "$_CHAN_PLANT_RC" "0"
assert_eq "B CONTROL a PARTIAL regression of a DELEGATED sub-verb is named" \
    "$(<"$WORK/sweep-chan.txt")" "ng skeptic resolve"
assert_eq "B CONTROL …and the fixture was restored byte-for-byte" \
    "$(cmp -s "$WORK/skeptic-channel.orig" "$_CHAN" && echo same)" "same"

# B POSITIVE CONTROL. Everything above asserts an absence; a verb that refused
# every invocation outright would satisfy all of it. Assert the natural order
# still reaches the API.
: > "$CAPTURE"
run_ng o e r show 12345
assert_contains "B CONTROL the natural order still reaches the API" "$(<"$CAPTURE")" 'api'
: > "$CAPTURE"
run_ng o e r show --repo "$BAD" 12345
assert_contains "B CONTROL …and so does the flag-first order" "$(<"$CAPTURE")" 'api'
# …and an extra positional is still refused, in both orders.
run_ng o e r show 1 2 3
assert_contains "B an extra positional is still refused" "$e" 'unexpected POSITIONAL argument'

# ===========================================================================
# PART C — the DIAGNOSTIC (your-org/nexus-code#906 R1, diagnostic axis).
#
# Getting the call shape right is not the only thing that matters; being told
# WHAT was wrong is. A bare token that does not start with `-` is an
# unexpected POSITIONAL, and calling it an "unknown flag" sends the reader
# hunting a flag name that was never the problem — at the exact moment they
# got the shape wrong and most needed to be told.
#
# Reported live: `ng request reply <id> "<900-char message>"` echoed the
# ENTIRE message back as a flag name. So the token must also be excerpted,
# for the same reason #858 C truncates: a long or multi-line value embedded in
# a diagnostic swamps it, and can survive a `| tail -1` looking like a value.
#
# Guarded because a diagnostic nobody asserts drifts back, and this entire PR
# exists because argument surfaces drift silently.
# ===========================================================================
echo '=== PART C: a bare positional is diagnosed as a positional, and excerpted ==='

_ch() {   # <script> <args...> → stderr of a direct channel-script invocation
    timeout 20 bash "$_test_dir/../$1" "${@:2}" </dev/null 2>&1 >/dev/null
}

LONG='Re-pinned sk903 rather than spawning a duplicate, and this message is long enough that echoing it whole is exactly the reported defect'
MULTI=$'first line of body\nsecond line\nthird line'

C_OUT=$(_ch request-channel.sh reply someid "$LONG")
assert_contains "C a bare positional is called a POSITIONAL, not a flag" "$C_OUT" 'unexpected POSITIONAL argument'
assert_not_contains "C …and NOT an unknown flag"                          "$C_OUT" 'unknown flag'
assert_contains "C …the probable flag is named"                           "$C_OUT" '--message/--file'
# POSITIVE assertions (your-org/nexus-code#906 R-b). Asserting the ABSENCE of
# a tail substring goes vacuous the moment somebody rewords this test's own
# fixture — the assertion would keep passing while witnessing nothing. Assert
# the ellipsis is PRESENT and the line is BOUNDED instead.
assert_contains "C …the token is excerpted (ellipsis present)"           "$C_OUT" '…'
_C_LEN=$(LC_ALL=C printf '%s' "$C_OUT" | wc -c)
if (( _C_LEN <= 260 )); then
    pass "C …and the whole diagnostic is bounded ($_C_LEN bytes)"
else
    fail "C the diagnostic is $_C_LEN bytes — the token is being echoed, not excerpted"
fi
assert_not_contains "C …and the tail of the token is gone"               "$C_OUT" 'exactly the reported defect'

C_MULTI=$(_ch request-channel.sh reply someid "$MULTI")
assert_contains "C a multi-line token names its dropped lines"            "$C_MULTI" '(+2 more line(s))'
assert_not_contains "C …without echoing the later lines"                  "$C_MULTI" 'third line'

# The other script, and a verb with no obvious hint — the message must still
# be right when there is nothing to suggest.
C_SK=$(_ch skeptic-channel.sh resolve task1 extra-token)
assert_contains "C skeptic-channel diagnoses a positional too"            "$C_SK" 'unexpected POSITIONAL argument'
assert_contains "C …and names ITS probable flag"                          "$C_SK" '--reason'
# A verb with NO obvious flag to suggest must not invent one. `poll` takes a
# task and nothing else, so there is nothing to name — the message has to be
# right when there is no hint, not only when there is.
C_NOHINT=$(_ch skeptic-channel.sh poll task1 extra-token)
assert_contains "C a hintless verb still diagnoses the positional"        "$C_NOHINT" 'unexpected POSITIONAL argument'
assert_not_contains "C …and does not invent a hint it does not have"      "$C_NOHINT" 'did you mean'

# CONTROL: a real unknown FLAG must still be called an unknown flag. Without
# this the suite would pass against a build that called everything a
# positional, which is the same defect with the polarity reversed.
# BOTH scripts (your-org/nexus-code#906 R-e). One witness is one script; the
# other could reorder its arms so `*)` shadows `--*)` and nothing here would
# notice — which is the single-line change this control exists to catch.
C_FLAG=$(_ch request-channel.sh reply someid --bogus)
assert_contains "C CONTROL a real unknown flag is still an unknown flag"  "$C_FLAG" 'unknown flag'
assert_not_contains "C CONTROL …and is not called a positional"           "$C_FLAG" 'unexpected POSITIONAL'
C_FLAG2=$(_ch skeptic-channel.sh resolve task1 --bogus)
assert_contains "C CONTROL skeptic-channel too: unknown flag stays a flag" "$C_FLAG2" 'unknown flag'
assert_not_contains "C CONTROL …and is not called a positional there either" "$C_FLAG2" 'unexpected POSITIONAL'

# C-DRIFT. `_arg_excerpt` is DEFINED IN THREE FILES — monitor/ng and both
# channel scripts — because they share no sourcing ancestor and giving them
# one would restructure the graph for a diagnostic helper. Three copies is how
# a fixed bug reappears where nobody looks, which is exactly what happened to
# this helper once already: written for #858 C, it capped LINES, and a
# 900-character SINGLE-line token walked through it for months because every
# instance that surfaced happened to be multi-line.
#
# So the copies are held equivalent BEHAVIOURALLY — same inputs, same output —
# rather than textually. A formatting difference is fine; a behavioural one is
# the drift, and a byte-identical check would cry wolf on the former while a
# textual diff of normalised source would still miss a semantic change.
echo '=== C-DRIFT: the three _arg_excerpt copies agree on every probe ==='
_excerpt_from() {   # <file> <token>
    bash -c 'source <(sed -n "/^_arg_excerpt() {/,/^}/p" "$1"); _arg_excerpt "$2"' _ "$1" "$2"
}
_EX_FILES=("$_test_dir/../ng" "$_test_dir/../request-channel.sh" "$_test_dir/../skeptic-channel.sh")
_EX_PROBES=(
    "hello"
    "$(printf '%.0sA' {1..200})"
    "$(printf '%.0s\u20ac' {1..200})"
    "$(printf 'first\nsecond\nthird')"
    ""
)
_ex_disagree=0; _ex_checked=0
for _pr in "${_EX_PROBES[@]}"; do
    _ref=$(_excerpt_from "${_EX_FILES[0]}" "$_pr")
    for _f in "${_EX_FILES[@]:1}"; do
        _ex_checked=$(( _ex_checked + 1 ))
        [[ "$(_excerpt_from "$_f" "$_pr")" == "$_ref" ]] || {
            _ex_disagree=$(( _ex_disagree + 1 ))
            printf '         %s disagrees on %q\n' "$(basename "$_f")" "$_pr" >&2
        }
    done
done
assert_eq "C-DRIFT the copies agree on every probe" "$_ex_disagree" "0"
if (( _ex_checked >= 8 )); then
    pass "C-DRIFT the comparison actually ran ($_ex_checked file/probe pairs [$(_slack "$_ex_checked" 8)])"
else
    fail "C-DRIFT only $_ex_checked pairs compared — the probe set or file list is broken"
fi
# …and the BYTE bound is the property, not the character count. 72 multi-byte
# characters is 219 bytes; capping characters alone left a 3x overshoot.
_EX_WIDE=$(_excerpt_from "${_EX_FILES[0]}" "$(printf '%.0s\u20ac' {1..200})")
_EX_BYTES=$(LC_ALL=C printf '%s' "$_EX_WIDE" | wc -c)
if (( _EX_BYTES <= 120 )); then
    pass "C-DRIFT a multi-byte token is BYTE-bounded ($_EX_BYTES bytes)"
else
    fail "C-DRIFT a multi-byte excerpt is $_EX_BYTES bytes — the cap is on characters, not bytes"
fi

# ===========================================================================
# PART D — COMPLETENESS of the excerpting, as a CLASS
# (your-org/nexus-code#906 R-c).
#
# Part C asserts the diagnostic is right for the sites it names. That is two
# instances patched, not a class guarded, and the difference was demonstrated:
# with this file at 30/30 green, `ng close 123 --<930 chars>` echoed a
# 950-BYTE token straight back, because the excerpting had been wired into the
# POSITIONAL arms and not into the `--*)` / `-*)` / `unknown subcommand` arms
# beside them. Same defect, same function, one arm over — and no assertion
# could see it, because no assertion described the class.
#
# THE CLASS: every argument-layer diagnostic that echoes a token the CALLER
# supplied (`$1`, `$2`, `$sub`) must pass it through `_arg_excerpt`. Stated
# that way it is checkable by reading, and a new arm joins the population the
# day it is written rather than the day somebody remembers it exists.
# ===========================================================================
echo '=== PART D: every argument diagnostic EXCERPTS the token it echoes ==='

# _raw_token_echoes — THE PROPERTY, not a list of wordings.
#
# THE FIRST CUT OF THIS PREDICATE WAS ITSELF THE DEFECT PART D EXISTS TO
# CATCH. It named a CLASS and matched a SPELLING: four literal phrases
# (`unknown flag`, `unknown subcommand`, `unexpected POSITIONAL`, `unexpected
# extra`) and the single emit verb `die`. Twenty-six live sites survived it at
# 43/0 green, across eleven surface files, echoing 982-1442 bytes of caller
# token whole — INCLUDING three in files D1 asserts at ZERO tolerance
# (your-org/nexus-code#911). Adding a fifth phrase would have been the same
# mistake a sixth time. `_dispatch_arms_of_script` two hundred lines above
# already matched an interposed word that this one did not, so the file
# disagreed with itself about what the class was.
#
# Stated as a property, boundedness has exactly TWO sources:
#   (a) the token passes through `_arg_excerpt`; or
#   (b) the ARM PATTERN is all-literal, so the token can only ever be one of
#       a finite set of strings the author wrote down (`--file|--message`) —
#       `die "$1 needs a value"` there echoes a flag NAME, not caller input.
# Everything else is unbounded caller input. So the predicate is:
#
#   inside a `case` switching on $1/$2/$sub (the argument layer),
#   in an arm whose pattern is NOT all-literal,
#   an emit that interpolates $1/$2/$sub, without `_arg_excerpt`.
#
# FAIL-CLOSED on the axis that used to be an allowlist: the ARM SHAPE is not
# enumerated. An arm pattern nobody anticipated contains a glob metacharacter
# and therefore lands IN the population rather than out of it — `*.txt)` is
# treated as unbounded, which is the safe direction. The emit is recognised
# by a verb set (die/printf/echo/warn/err) OR by a bare `>&2` redirect, so an
# emit verb this file has never heard of is still caught the moment it names
# stderr.
#
# DECLARED COVERAGE BOUNDARY. This predicate reads the argument layer as
# `case`-shaped and keys on the token being written `$1`/`$2`/`$sub` AT THE
# DIAGNOSTIC. It is therefore blind to a caller token that reaches the
# diagnostic through a VARIABLE — `content="$1"` in the loop, validated after
# it — and to emits that are not line-shaped, such as a `cat >&2 <<EOF`
# heredoc.
#
# THE PREVIOUS VERSION OF THIS PARAGRAPH ASSERTED "measured at this head: no
# surface script parses arguments that way." THAT WAS FALSE, and it is the
# defect this PR is about, committed one layer out: not in the predicate, but
# in the boundary declaration ABOUT the predicate. Twelve live sites sat behind
# it, echoing 985-1565 bytes, including `ng:827` three lines under an arm this
# PR had already fixed. A boundary sentence is what a reader trusts INSTEAD of
# re-measuring, so a false one is worse than none.
#
# The boundary is therefore no longer prose you must take on trust. The shapes
# named above are covered BEHAVIOURALLY by PART E below, which drives real
# commands with an oversized token and measures stderr — immune to spelling
# because it observes bytes, not source text. Part E carries its own positive
# control and a non-vacuity floor, and its scope is a table you can read.
# What remains outside BOTH is stated there, not here.
_raw_token_echoes() {   # <file> → "N:line" for each arg diagnostic echoing an UNBOUNDED token
    gawk '
      function is_literal_arm(p,   n, a, i, alt, q) {
          q = sprintf("%c", 39)
          sub(/^[[:space:]]*\(?/, "", p); sub(/[[:space:]]+$/, "", p)
          n = split(p, a, "|")
          for (i = 1; i <= n; i++) {
              alt = a[i]
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", alt)
              gsub("^[\"" q "]|[\"" q "]$", "", alt)
              if (alt == "")        return 0     # empty  => cannot vouch
              if (alt ~ /[*?[]/)    return 0     # glob   => unbounded
          }
          return 1
      }
      function has_tok(s) { return (s ~ /\$\{?(1|2|sub)([^A-Za-z_0-9]|$)/) }
      BEGIN { depth = 0 }
      {
        line = $0
        if (line ~ /(^|[;&|[:space:]])case[[:space:]]/) {
            depth++
            argcase[depth]  = (line ~ /case[[:space:]]+"?\$\{?(1|2|sub)([^A-Za-z_0-9]|$)/) ? 1 : 0
            state[depth]    = "PAT"
            catchall[depth] = 0
        }
        active = 0
        for (i = 1; i <= depth; i++) if (argcase[i]) active = 1

        if (active && depth > 0 && line !~ /^[[:space:]]*#/) {
            if (state[depth] == "PAT" && line ~ /\)/ && line !~ /(^|[;[:space:]])esac/) {
                pat = line; sub(/\).*$/, "", pat)
                catchall[depth] = is_literal_arm(pat) ? 0 : 1
                state[depth] = "BODY"
            }
            if (state[depth] == "BODY" && catchall[depth] && line !~ /_arg_excerpt/) {
                hit = 0
                if (match(line, /(^|[^A-Za-z_0-9])(die|printf|echo|warn|err)([[:space:]])/)) {
                    if (has_tok(substr(line, RSTART + RLENGTH))) hit = 1
                }
                if (!hit && line ~ />&2/ && has_tok(line)) hit = 1
                if (hit) printf "%d:%s\n", FNR, line
            }
            if (line ~ /;;/) state[depth] = "PAT"
        }
        if (line ~ /(^|[;[:space:]])esac([[:space:]]|;|$)/ && depth > 0) depth--
      }
    ' "$1"
}

# D0. POSITIVE CONTROLS FIRST — D1 is an absence, and a broken predicate
#     reports one for free (your-org/nexus-code#938: a negative result without
#     a positive control in the same run is not a measurement).
#
#     There are FOUR of them because the predicate this replaced passed a
#     single control while twenty-six real sites walked past it. One control
#     of the shape you already thought of cannot tell you about the shapes you
#     did not — so each leg here varies ONE axis the old predicate was blind
#     on, and D0e/D0f pin the polarity so the widening cannot pass by simply
#     matching everything.
D_FIX="$WORK/raw-die.sh"
cat > "$D_FIX" <<'FIXTURE'
cmd_planted_raw() {
    while (( $# > 0 )); do
        case "$1" in
            --repo) shift 2 ;;
            --*) die "unknown flag: $1" ;;
        esac
    done
}
FIXTURE
assert_contains "D0a CONTROL the lint sees a planted raw-token die" \
    "$(_raw_token_echoes "$D_FIX")" 'unknown flag: $1'

# D0b. AXIS: emit verb `echo`, and a wording in none of the four phrases the
#      old predicate listed. This is upload-asset.sh:112 in miniature.
D_ECHO="$WORK/raw-echo.sh"
cat > "$D_ECHO" <<'FIXTURE'
cmd_planted_echo() {
    while (( $# > 0 )); do
        case "$1" in
            --keep) shift ;;
            -*) echo "bogus doohickey: $1" >&2; exit 1 ;;
        esac
    done
}
FIXTURE
assert_contains "D0b CONTROL a novel WORDING on an echo is still seen" \
    "$(_raw_token_echoes "$D_ECHO")" 'bogus doohickey: $1'

# D0c. AXIS: `printf`, the `$sub` dispatcher token, and `%q` — which quotes
#      but does NOT bound, so it is not excerpting. write-probe.sh:89.
D_PRINTF="$WORK/raw-printf.sh"
cat > "$D_PRINTF" <<'FIXTURE'
cmd_planted_printf() {
    case "$sub" in
        status) return 0 ;;
        *) printf 'no such widget %q\n' "$sub" >&2; exit 2 ;;
    esac
}
FIXTURE
assert_contains "D0c CONTROL a printf %q of \$sub is still seen" \
    "$(_raw_token_echoes "$D_PRINTF")" 'no such widget'

# D0d. AXIS: an emit verb this file has never heard of. The verb set is an
#      allowlist and therefore cannot be complete; the `>&2` arm is what makes
#      the omission non-fatal. If this leg ever goes quiet, the predicate has
#      silently become an allowlist again — which is the whole finding.
D_NOVEL="$WORK/raw-novel-verb.sh"
cat > "$D_NOVEL" <<'FIXTURE'
cmd_planted_novel_verb() {
    case "$1" in
        --dry-run) shift ;;
        *) log_error "mystery token: $1" >&2 ;;
    esac
}
FIXTURE
assert_contains "D0d CONTROL an UNKNOWN emit verb naming stderr is still seen" \
    "$(_raw_token_echoes "$D_NOVEL")" 'mystery token: $1'

# D0e. POLARITY: a correctly-excerpted arm must NOT be reported. Without this,
#      a predicate that matched every line would pass D0a-D0d.
D_OK="$WORK/excerpted.sh"
cat > "$D_OK" <<'FIXTURE'
cmd_planted_excerpted() {
    while (( $# > 0 )); do
        case "$1" in
            --*) die "unknown flag: $(_arg_excerpt "$1")" ;;
        esac
    done
}
FIXTURE
assert_empty "D0e POLARITY an excerpted arm is NOT reported" \
    "$(_raw_token_echoes "$D_OK")"

# D0f. POLARITY: source (b) of boundedness. An ALL-LITERAL arm pattern bounds
#      the token to the strings the author wrote down, so `die "$1 needs a
#      value"` there echoes a flag NAME, not caller input. request-channel.sh
#      does exactly this twice, and it is correct; reporting it would make the
#      residue ratchet below carry noise that nobody can act on.
D_BOUND="$WORK/bounded-arm.sh"
cat > "$D_BOUND" <<'FIXTURE'
cmd_planted_bounded() {
    while (( $# > 0 )); do
        case "$1" in
            --file|--message) body_args+=("$1" "${2:-}"); shift 2 || die "$1 needs a value" ;;
        esac
    done
}
FIXTURE
assert_empty "D0f POLARITY an ALL-LITERAL arm pattern bounds the token" \
    "$(_raw_token_echoes "$D_BOUND")"

# D1. Zero tolerance for the files that HAVE the helper. Population derived:
#     `monitor/ng` plus every surface script that defines `_arg_excerpt`.
_D_FILES=()
for _f in "$NG_SRC" $(_ng_surface_scripts | sed "s|^|$(dirname "$NG_SRC")/|"); do
    [[ -r "$_f" ]] && grep -q '^_arg_excerpt() {' "$_f" && _D_FILES+=("$_f")
done
_D_RAW=""
for _f in "${_D_FILES[@]}"; do
    _r=$(_raw_token_echoes "$_f")
    [[ -n "$_r" ]] && _D_RAW+="$(basename "$_f"): $_r"$'\n'
done
assert_empty "D1 no arg diagnostic echoes a raw token in a file that has _arg_excerpt" "$_D_RAW"
if (( ${#_D_FILES[@]} >= 3 )); then
    pass "D1 …across ${#_D_FILES[@]} helper-bearing files (ng + the two channel scripts) [$(_slack "${#_D_FILES[@]}" 3)]"
else
    fail "D1 only ${#_D_FILES[@]} helper-bearing files found — the population is broken, not the files"
fi

# D2. THE RESIDUE, as a SHRINK-ONLY RATCHET rather than an undeclared silence.
#     Ten surface scripts still echo raw tokens and do NOT define the helper.
#     They are recorded, with counts and a reason each, because the fix is to
#     give the four copies a shared ancestor — a graph change this PR should
#     not make while it is trying to merge — not to paste a FOURTH and FIFTH
#     copy into files that would then drift, which is the failure C-DRIFT
#     below exists to catch. Measured 2026-08-14.
#
#     The ratchet bites BOTH ways: a NEW raw site, or a new file joining, fails
#     here; and so does a row whose count has DROPPED, because a fixed script
#     left in the manifest teaches the next reader that it is still broken.
#     The counts are `_raw_token_echoes`' OWN, at e9b2d2d+. Stated that way
#     deliberately: the first draft of this manifest said `remote-enroll.sh 5`,
#     from a hand grep that omitted `$sub` — a number produced by a DIFFERENT
#     predicate than the one that checks it. Five was not a wrong count of
#     anything; it was a correct count of something else. Re-measure with
#     `_raw_token_echoes <file>`, never by eye.
#
#     RE-BASELINED 2026-08-15 (your-org/nexus-code#911) when the predicate
#     above became property-based. The manifest grew 2 files / 8 sites → 10
#     files / 23 sites WITHOUT ONE LINE OF PRODUCTION CODE CHANGING HERE: the
#     seventeen new rows were always present, and the old predicate could not
#     see them. That is the finding, recorded as a number rather than as a
#     sentence. `lit.sh` went 2 → 3 for the same reason — its third site says
#     `unknown lit subcommand`, and the interposed word made it invisible to a
#     predicate that matched `unknown subcommand` literally.
#     ELEVENTH ROW ADDED at the B1 bundle seam: `obligations.sh` is NEW in
#     your-org/nexus-code#845, which branched before this predicate existed, so
#     it entered the surface population already echoing raw tokens in 7 arg
#     diagnostics. The ratchet caught it on the merge — which is the ratchet
#     working, not a defect in `#845`. It is RECORDED rather than fixed for the
#     reason the paragraph above gives: the fix is a shared ancestor for the
#     four `_arg_excerpt` copies, and pasting a FIFTH into a brand-new file is
#     the drift C-DRIFT exists to catch. The count is `_raw_token_echoes`' own
#     output at the seam, not a hand grep — re-measure with
#     `_raw_token_echoes monitor/obligations.sh`, never by eye.
#     TWELFTH ROW ADDED at the #1014 merge seam: `remote-client-helper.sh` is
#     NEW in your-org/nexus-code#1014 and joined the surface population with ONE
#     raw-token arg diagnostic — `monitor/remote-client-helper.sh:201`, an
#     unbounded `$1` in `die "unknown flag: $1 (…)"`. Same shape as the
#     `obligations.sh` row above and treated the same way: the ratchet caught a
#     new file joining, which is the ratchet working, not a defect in `#1014`,
#     and it is RECORDED rather than fixed because the fix is a shared ancestor
#     for the `_arg_excerpt` copies and pasting a FIFTH into a brand-new file is
#     the drift C-DRIFT exists to catch. The count is `_raw_token_echoes`' own
#     output at the seam — re-measure with
#     `_raw_token_echoes monitor/remote-client-helper.sh`, never by eye. The
#     calibration that says the predicate is the one checking it: the same run
#     returns 6 for `remote-enroll.sh`, the row directly below.
#     `obligations.sh` 7 -> 8 at the W2-16 seam (your-org/nexus-code#1270
#     residual A): the new `preserve-closures` subcommand joined the surface
#     population with ONE raw-token arg diagnostic, `*) die "unknown flag: $1"`,
#     in the same shape as the seven arms already in that file. RECORDED, not
#     fixed, for the reason this block gives twice above: the fix is a shared
#     ancestor for the `_arg_excerpt` copies, and pasting a FIFTH into a file
#     that has none is exactly the drift C-DRIFT exists to catch. Writing the
#     new arm differently from its seven siblings would have hidden it from this
#     ratchet while leaving the class untouched — the ratchet caught a new site
#     joining, which is it working. The count is `_raw_token_echoes`' own output
#     at the seam, re-measured after the change, never a hand grep.
#     THIRTEENTH ROW ADDED at the bundle-2609 seam (your-org/nexus-code#1535):
#     `longjob-watch.sh` is NEW and joined the surface population (`ng longjob`
#     is a `_facade`) with THREE raw-token arg diagnostics — `add: unknown
#     option $1`, `add: one subject only (got '$subject' and '$1')`, `run:
#     unknown option $1`. Same shape as the rows above, treated the same way:
#     RECORDED, not fixed, for the shared-ancestor reason. The count is
#     `_raw_token_echoes`' own output on the merged tree — re-measure with
#     `_raw_token_echoes monitor/longjob-watch.sh`, never by eye.
_D_MANIFEST='ci-head-attempts.sh 2
longjob-watch.sh 3
guards-for-diff.sh 1
lit.sh 3
mint-token.sh 1
obligations.sh 8
paste-followup.sh 1
remote-client-helper.sh 1
remote-enroll.sh 6
reports-roll.sh 1
upload-asset.sh 6
user-pat.sh 1
write-probe.sh 1'
_D_LEDGER=""
for _f in $(_ng_surface_scripts); do
    _p="$(dirname "$NG_SRC")/$_f"
    [[ -r "$_p" ]] || continue
    grep -q '^_arg_excerpt() {' "$_p" && continue
    _n=$(_raw_token_echoes "$_p" | wc -l)
    (( _n > 0 )) && _D_LEDGER+="$_f $_n"$'\n'
done
assert_eq "D2 the recorded raw-token residue matches the manifest exactly" \
    "$(printf '%s' "$_D_LEDGER" | sort)" "$(printf '%s\n' "$_D_MANIFEST" | sort)"

# ===========================================================================
# PART E — the class, checked BEHAVIOURALLY (your-org/nexus-code#911 F-A).
#
# WHY THIS EXISTS, and it is the whole lesson of #906/#911: Part D is a STATIC
# predicate, and every static narrowing of this class has turned out to be a
# SPELLING. The history, all measured:
#
#   1. the original matched four literal phrases + `die`   → 26 sites survived
#   2. the #911 rewrite keyed on the ARM, fail-closed      → sound, but blind
#      to a token that reaches the diagnostic through a VARIABLE
#   3. a var-taint predicate keyed on `*)` at line start   → missed the
#      ONE-LINER `case "$x" in a|b) ;; *) die … ;; esac`  (ng:827, ng:866)
#   4. …and keyed the failure path on `||`                 → missed
#      `if <test>; then die; fi` (ng:1565) and a `cat >&2 <<EOF` HEREDOC
#      (ng:1476), which no emit-verb predicate can see at all
#
# Four predicates, four blind spots, each found only by RUNNING the command.
# The previous version of this file declared the residual shape in prose and
# asserted "no surface script parses arguments that way" — a boundary that was
# honest in shape and FALSE in fact, which is worse than none, because it
# stops the next reader from looking. Twelve live sites were behind it.
#
# So the boundary is no longer a sentence. It is this probe table. Each entry
# drives a real command with an oversized token and MEASURES stderr. That is
# immune to spelling by construction: it observes the bytes the caller would
# actually see. An excerpted diagnostic is ~100-160 B; a raw echo is ~1000 B.
#
# DECLARED SCOPE, measured not asserted: these are LOCAL-ONLY invocations that
# die in the argument/validation layer before any network call. Verbs that
# perform a GitHub write are deliberately NOT probed — naming that exclusion
# rather than leaving it implied is the whole point of the entry above.
# ===========================================================================
echo '=== PART E: oversized caller tokens do not reach stderr whole ==='

_E_CAP=300
_E_TOK=$(printf 'A%.0s' {1..950})
_E_STATE="$WORK/e-state"; mkdir -p "$_E_STATE"
_ng_dir="$(dirname "$NG_SRC")"

_e_bytes() {   # <cmd…> → stderr byte count
    NEXUS_STATE_DIR="$_E_STATE" timeout 30 "$@" 2>&1 >/dev/null | LC_ALL=C wc -c
}

# E0. POSITIVE CONTROL FIRST — an absence measured by a probe that cannot fail
#     is not a measurement (#938). Plant a script that echoes the token whole.
_E_FIX="$WORK/e-raw.sh"
cat > "$_E_FIX" <<'FIXTURE'
#!/usr/bin/env bash
case "${1:-}" in
    --keep) shift ;;
    *) echo "planted raw echo: ${1:-}" >&2; exit 1 ;;
esac
FIXTURE
_E_CTRL=$(_e_bytes bash "$_E_FIX" "$_E_TOK")
if (( _E_CTRL > _E_CAP )); then
    pass "E0 CONTROL a planted raw echo exceeds the cap ($_E_CTRL B > $_E_CAP B)"
else
    fail "E0 CONTROL the probe cannot see a raw echo ($_E_CTRL B) — every E1 pass below is vacuous"
fi

# E1. THE PROBE TABLE. `%TOK%` is substituted with the oversized token.
_E_TABLE=(
    "ng react|$_ng_dir/ng|react|123|%TOK%"
    "ng react-issue|$_ng_dir/ng|react-issue|5|%TOK%"
    "ng report-check|$_ng_dir/ng|report-check|%TOK%"
    "rc file --origin|$_ng_dir/request-channel.sh|file|--origin|%TOK%|--slug|s"
    "rc file --slug|$_ng_dir/request-channel.sh|file|--origin|w|--slug|%TOK%"
    "rc file --kind|$_ng_dir/request-channel.sh|file|--origin|w|--slug|s|--kind|%TOK%"
    "rc show|$_ng_dir/request-channel.sh|show|%TOK%"
    "rc reqfile|$_ng_dir/request-channel.sh|reqfile|%TOK%"
    "rc fetch|$_ng_dir/request-channel.sh|fetch|%TOK%|status"
    "rc reply|$_ng_dir/request-channel.sh|reply|%TOK%|--message|m"
    "rc unknown-flag|$_ng_dir/request-channel.sh|file|--%TOK%"
    "sc ask|$_ng_dir/skeptic-channel.sh|ask|t|s|%TOK%"
    "sc nudge|$_ng_dir/skeptic-channel.sh|nudge|%TOK%"
    "sc answer|$_ng_dir/skeptic-channel.sh|answer|%TOK%|--message|m"
    "ng unknown-flag|$_ng_dir/ng|react|--%TOK%"
)
_E_OVER=""
_E_PROBES=0
for _row in "${_E_TABLE[@]}"; do
    IFS='|' read -r -a _parts <<< "$_row"
    _label="${_parts[0]}"
    _cmd=()
    for _a in "${_parts[@]:1}"; do
        [[ "$_a" == "%TOK%" ]] && _cmd+=("$_E_TOK") || _cmd+=("${_a//%TOK%/$_E_TOK}")
    done
    [[ -x "${_cmd[0]}" || -r "${_cmd[0]}" ]] || continue
    _E_PROBES=$(( _E_PROBES + 1 ))
    _n=$(_e_bytes bash "${_cmd[@]}")
    (( _n > _E_CAP )) && _E_OVER+="$_label: $_n bytes"$'\n'
done
assert_empty "E1 no probed diagnostic echoes an oversized token (cap ${_E_CAP} B)" "$_E_OVER"
if (( _E_PROBES >= 12 )); then
    pass "E1 …across $_E_PROBES live probes over three helper-bearing scripts"
else
    fail "E1 only $_E_PROBES probes ran — the table or the paths are broken, not the diagnostics"
fi

# ---- the floors this file declares must BE the floors it contains ---------
# The first cut of the declaration above was a hand-written list scoped to one
# file, and it missed four bounds in the sibling guard. A declaration nobody
# checks decays into the thing it was written to prevent.
_bound_names() {   # <file> → names bounded by `>= <int>` in bash arithmetic
    gawk '
      /^[[:space:]]*#/ { next }
      !/\(\(/          { next }
      { s = $0
        while (match(s, /(\$\{#)?([A-Za-z_][A-Za-z_0-9]*)(\[@\]\})?[[:space:]]*>=[[:space:]]*[0-9]+/, m)) {
            print m[2]; s = substr(s, RSTART + RLENGTH) } }
    ' "$1" | sort -u
}
_declared_bounds() {   # <file> → names listed in the inventory block
    # The marker is ASSEMBLED, never written whole: a literal here would make
    # sed match THIS LINE and open a second range over the extractor's own
    # source. Measured in the sibling guard — it reported `expectation matches`
    # as a declared bound.
    local _m="BOUND-INVENTORY"
    sed -n "/BEGIN $_m/,/END $_m/p" "$1" \
        | gawk 'match($0,/^#[[:space:]]+([A-Za-z_][A-Za-z_0-9]*)([[:space:]]|$)/,m){print m[1]}' | sort -u
}
_SELF="$_test_dir/$(basename "${BASH_SOURCE[0]}")"
assert_eq "every population floor in this file is declared in its inventory" \
    "$(_bound_names "$_SELF" | tr '\n' ' ')" "$(_declared_bounds "$_SELF" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, ledger=yes level).
#   5  Part A: two controls, the property, the delegated non-vacuity, the population sanity check
# + 2  Part B: the dispatcher-driven sweep + its population sanity check
# + 3  Part B-REACH: sub-verbs reach their parser (#906 N1), plus the DERIVED
#        population reconciliation both ways (#943)
# + 2  Part B-DOC:  the documentation axis reconciles + non-vacuity (#906 N2)
# + 1  Part B: the planted-old-shape control
# + 3  Part B: the planted PARTIAL regression of a DELEGATED sub-verb —
#        applied-check, the finding, and the byte-for-byte restore (#906 N1)
# + 1  Part B: the FIXTURE control — the stub mint-token survives the delegate
#        installer (your-org/nexus-code#1339). Not decoration: the installer
#        used to overwrite it with the REAL mint-token.sh, which cannot mint in
#        a fake nexus, and the two `reaches the API` controls below then passed
#        only because `ng`'s `api()` absorbed the resulting `die` inside
#        `GH_TOKEN=$(token)` and called `gh` with an EMPTY token. Measured, one
#        variable: defect rc=0 capture=[api /repos/…], hoisted rc=1 capture=[].
# + 3  Part B: two positive controls + the extra-positional refusal
# +16  Part C: the diagnostic axis, its polarity control on BOTH scripts,
#        and the positive length assertions
# + 3  Part C-DRIFT: three-copy equivalence + the byte bound
# + 9  Part D: FOUR positive controls (die / a novel wording on echo / printf
#        %q of $sub / an unknown emit verb reaching stderr) + TWO polarity
#        controls (an excerpted arm, and an all-literal arm pattern), then the
#        zero-tolerance property + its population non-vacuity, and the
#        shrink-only residue ratchet (#906 R-c, widened to the property #911)
# + 3  Part E: the BEHAVIOURAL axis (#911 F-A) — the planted-raw-echo control,
#        the cap over the probe table, and the probe-count non-vacuity
# + 1  the bound inventory is complete (#943)
EXPECTED=$(( 5 + 2 + 3 + 2 + 1 + 3 + 1 + 3 + 16 + 3 + 9 + 3 + 1 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
