#!/usr/bin/env bash
# Every flag an `ng` verb PARSES must appear in that verb's own `--help` —
# your-org/nexus-code#906 A, which is #883's class in the tool with the most
# call sites.
#
# `#883` closed the instance in `paste-followup.sh` by DERIVING the synopsis
# from the parser, and asked for the generalisation to be scoped separately,
# saying: *"a cheap guard could diff the parsed-flag set against the usage
# string … I have not enumerated how many other flags are in it, and the count
# should be measured before the guard is scoped."* It is now measured: 101
# parsed `(verb, --flag)` pairs in `monitor/ng`, 100 with a `_usage_for` arm to
# compare against, **12** absent from it.
#
# Deriving `ng`'s synopsis the way `paste-followup.sh` does is the better
# long-run answer, but `ng` has 48 verbs and one shared `_usage_for` table, so
# that is a rewrite. This is the other half of what `#883` asked for: a guard
# that fails loud when the two disagree, so the population can only shrink.
#
# WHY A RATCHET AND NOT A GREEN-OR-RED WALL. Eleven of the twelve are the
# `--skeptic-*` family on `cmd_wrap_up`, and that family's SEMANTICS are under
# active change (`#879` wants a flag that does not exist yet; `#881` wants an
# omitted `--skeptic-findings` to stop being recorded as a measured 0).
# Advertising a flag set that is about to change would be churn, and worse,
# whoever changes it would have to touch a string this guard also reads. So the
# known drifts are recorded here with their reason, the guard fails on anything
# NEW, and — this is the half that makes it a ratchet rather than a
# suppression — it ALSO fails when a recorded drift is FIXED and left in the
# manifest. The list can only shrink.
#
# THE MEASUREMENT'S OWN FAILURE MODE, which is why the sanity floor exists.
# The pass that produced this count first reported 15 drifts and then 0. The 15
# came from capturing only the FIRST line of `wrap-up`'s two-line usage arm;
# the 0 came from a mis-keyed lookup that silently skipped every comparison.
# A lookup that matches nothing reports zero drifts and looks like success —
# this repo's dominant defect class, arriving inside the probe written to
# attack it. Hence `checked`, asserted before any verdict — originally against
# a FLOOR, which turned out to be the same defect one level up
# (your-org/nexus-code#943): `DCHECKED >= 40` against a true 89 tolerated losing
# 42 % of the population, `request-channel.sh` included, while printing that the
# walk had happened. The non-vacuity is now DERIVED and asserted as equality;
# see "NON-VACUITY, DERIVED" below.
#
# ---- POPULATION FLOORS IN THIS FILE, declared and self-checked -------------
#
# There are none, and the assertion at the foot of this file proves it rather
# than asserting it: it greps this file for `(( … >= <int> … ))` in bash
# arithmetic context and compares the set of bounded names to the inventory
# between the markers below. Add a floor without declaring it and the guard
# fails. The sibling guard `test-ng-flag-order.sh` carries the same block and
# declares SEVEN, which is where the remaining members of this class live.
#
# NOT in scope, and the distinction is deliberate: `<=` bounds on a DIAGNOSTIC
# (`_C_LEN <= 260` there) are the property itself — "do not swamp the reader" —
# not a number standing in for a measured population. A floor proxies for a
# measurement; a cap IS the measurement.
#
# <!-- BEGIN BOUND-INVENTORY -->
# (none)
# <!-- END BOUND-INVENTORY -->
#
# Run: bash monitor/watcher/test-ng-usage-flag-coverage.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_SRC="$_test_dir/../ng"

WORK=$(mktemp -d -t nexus-906a-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ── PIN THE STATE DIR (your-org/nexus-code#1336, #1349) ────────────────────
#
# This suite RUNS the real `ng`, which resolves its state directory through a
# FOUR-arm chain. Only arm 1 (`NEXUS_STATE_DIR`) is unconditional; the rest are
# fallbacks that cannot be switched off by REMOVING something:
#
#   1. $NEXUS_STATE_DIR                     <- the only arm that cannot be fallen past
#   2. $NEXUS_ROOT/monitor/.state
#   3. config nexus.root + /monitor/.state  <- the arm nobody accounts for
#   4. $_script_dir/.state
#
# So `env -u NEXUS_ROOT` does NOT isolate: it ADVANCES the search to arm 3,
# which on an operator's primary IS the primary, and in an UNCONFIGURED clone
# is the literal `nexus.root` placeholder — a real, writable directory on this
# host holding five days of accumulated rows. Measured before this pin:
# `monitor/.state/ng-usage.jsonl` written into the inherited root on every local
# run, verdict LEAK, `#1336`.
#
# `fixture_suites()` cannot see this suite at all — its NG arm greps four
# spellings and this one reaches `ng` as `"$_test_dir/../ng"`, which has no
# `/monitor/ng` substring — so the CI gate never selected it. Pinning arm 1 is
# correct regardless of whether the population predicate is ever widened.
# `th_pin_ng_state` pins arm 1 and PROVES it in both directions; a bare export
# is the same instruction with no evidence (your-org/nexus-code#1306).
th_pin_ng_state "$NG_SRC" "$WORK/state"
# The SECOND resolver: `monitor/gh-capable.sh:_ghc_cache_dir` is an independent
# chain (`NEXUS_GH_CAPABLE_CACHE`, else `$NEXUS_ROOT/monitor/.state/gh-capable.d`)
# that never consults `NEXUS_STATE_DIR`, so arm 1 alone does not contain it.
export NEXUS_GH_CAPABLE_CACHE="$WORK/state/gh-capable.d"

command -v gawk >/dev/null 2>&1 || { th_skip "gawk absent" "this guard uses gawk's match(...,arr)"; th_summary_and_exit; }

# ---- the known population, and WHY each is still here ---------------------
#
# THE SKEPTIC FAMILY IS NO LONGER HERE, AND THAT IS THE RATCHET WORKING.
#
# This guard shipped recording eleven `cmd_wrap_up --skeptic-*` flags as
# parsed-but-unadvertised, held deliberately while #879/#881 settled their
# semantics. Merging `dev` (PR #869) advertised all eleven in wrap-up's usage
# arm — and the STALE half of this guard went red on the merge, naming every
# row and demanding it be deleted. That is precisely the direction a
# suppression list cannot have: the population shrank because the guard
# refused to let a discharged hold sit here looking like an obligation.
#
# What remains is `monitor/remote-enroll.sh`, reached through the DELEGATED
# population (#906 F2): the boundary is the verbs `ng` EXPOSES, not the lines
# monitor/ng CONTAINS, so every script `ng` delegates a verb to is in scope.
#
# EACH ROW CARRIES ITS OWN REASON, and a row without a substantive one is
# itself a failure. A bare list of names invites the next reader to go green
# by pasting strings into a usage string, which can be the wrong fix — the
# reason is what says whether advertising THIS row is yet correct.
#
# Format: <script-or-cmd_fn> <flag> | <reason>. Only the first two fields are
# compared; the reason is prose, echoed back in the stale diagnostic. Delete a
# row when its flag reaches the surface — leaving it is a FAILURE.
KNOWN_DRIFT_ROWS=$(cat <<'ROWS'
monitor/remote-enroll.sh --comment | SCOPE-HOLD. This script's help surface is a HEADER-COMMENT DUMP, not a usage string, and the flag is described in prose further down the file (out of the dumped block) — the #883 shape exactly. Documenting four remote-channel flags correctly needs that feature's owner; this PR does not otherwise touch remote-access. Recorded so it is a tracked obligation rather than an unknown.
monitor/remote-enroll.sh --explicit | SCOPE-HOLD, same as --comment: header-dump help surface, remote-access feature, not touched by this PR.
monitor/remote-enroll.sh --no-shell-belt | SCOPE-HOLD, same as --comment. Note it IS described in prose at remote-enroll.sh:537 — below the dumped header block, so a caller reading the help never reaches it. That is #883's shape, not an absence of documentation.
monitor/remote-enroll.sh --token-stdin | SCOPE-HOLD, same as --comment: header-dump help surface, remote-access feature, not touched by this PR.
ROWS
)
# The comparison key: first two whitespace-separated fields only.
KNOWN_DRIFT=$(awk -F' *\\| *' 'NF{print $1}' <<<"$KNOWN_DRIFT_ROWS" | awk 'NF{print $1, $2}')

# ---- the measurement ------------------------------------------------------

# (verb, flag) actually parsed. Alias arms (`--a|--b)`) are split, because an
# unadvertised ALIAS is exactly the #883 shape (`--no-retask` was one).
_parsed_pairs() {
    gawk '
      match($0,/^cmd_([a-z0-9_]+)\(\) \{/,f){fn="cmd_" f[1]; inf=1}
      inf && /^\}/ {inf=0; fn=""}
      inf && match($0,/^[[:space:]]*(--[a-zA-Z0-9|_-]+)\)/,m) && fn {
          n=split(m[1],alts,"|"); for(i=1;i<=n;i++) print fn "\t" alts[i]
      }' "$1" | sort -u
}

# Each verb's usage arm, captured WHOLE. Multi-line arms are the trap: a
# first-line-only capture reports three false drifts on `wrap-up` alone.
_usage_arms() {
    gawk '
      /^_usage_for\(\)/ {inu=1}
      inu && match($0,/^[[:space:]]*(cmd_[a-z0-9_]+)\)/,m) { cur=m[1]; buf="" }
      inu && cur { buf = buf $0 " "; if ($0 ~ /;;[[:space:]]*$/) { print cur "\t" buf; cur="" } }
      inu && /^\}/ {inu=0}
    ' "$1"
}

# Writes drifts to $2 and the checked-count to $3. NOT a command
# substitution: `CHECKED=` set inside `$( … )` dies with the subshell, and the
# non-vacuity assertion that reads it would then be the very silent-zero this
# guard exists to catch. Measured — it failed exactly that way first.
_drifts() {   # <ng-file> <drift-out> <checked-out> <skipped-out>
    local ng="$1" out="$2" cnt="$3" skip="$4" fn flag arm
    _parsed_pairs "$ng" > "$WORK/parsed.tsv"
    _usage_arms  "$ng" > "$WORK/usage.tsv"
    local checked=0
    : > "$out"; : > "$skip"
    while IFS=$'\t' read -r fn flag; do
        arm=$(awk -F'\t' -v k="$fn" '$1==k{print $2; exit}' "$WORK/usage.tsv")
        # No usage arm at all. RECORDED, not silently skipped: a bare
        # `continue` here means a whole verb leaves the comparison without
        # leaving a trace, and the floors that used to stand in for
        # non-vacuity could not tell that from a healthy walk.
        [[ -n "$arm" ]] || { printf '%s %s\n' "$fn" "$flag" >> "$skip"; continue; }
        checked=$(( checked + 1 ))
        case "$arm" in *"$flag"*) ;; *) printf '%s %s\n' "$fn" "$flag" >> "$out" ;; esac
    done < "$WORK/parsed.tsv"
    printf '%s' "$checked" > "$cnt"
}

# ---- the DELEGATED scripts (your-org/nexus-code#906 F2) ------------------
#
# THE POPULATION IS THE VERBS `ng` EXPOSES, NOT THE LINES `monitor/ng`
# CONTAINS. `ng` delegates whole verbs to sibling scripts — `ng skeptic` to
# skeptic-channel.sh, `ng pane-state` to pane-state.sh, `ng upload` to
# upload-asset.sh, and so on — and a flag parsed there is exactly as
# undiscoverable as one parsed here. The first cut of this guard walked the
# FILE and so could not see them; `ng skeptic resolve --disposition` was the
# live instance that exposed the boundary.
#
# Each delegated script carries its own usage surface rather than an entry in
# `_usage_for`, so the property is the same one stated per script: every flag
# it parses appears in the help it prints.
#
# `ng` delegates by TWO forms and this grep reads one — the `"$_script_dir/…"`
# shape. The other is the one-line `_facade <name>.sh`, enumerated by
# `_ng_surface_scripts` below. A facade script is therefore either ENROLLED
# here or recorded in `_D_UNWALKED` with a reason; one in NEITHER goes red by
# name in the reconciliation. That is how `#1070` surfaced: `#1065` added
# `monitor/send.sh` as `cmd_send() { _facade send.sh "$@"; }`, the walk could
# not see it, and the guard named all fifteen of its flags as UNWALKED.
#
# `send.sh` is enrolled rather than excused. The exclusion list's own reason is
# that those flags "have never been measured" — false for `send.sh` the moment
# anyone measures it, and measuring it found SIX genuinely undiscoverable flags
# (`--administrative`, `--no-retask`, `--note`, `--issue`, `--comment`,
# `--confirm-timeout`: all forwarded to the transport, all documented on
# `paste-followup.sh`, none on `ng send --help`). Excusing it would have
# suppressed a real `#883` instance to make a correct complaint go quiet.
# `longjob-watch.sh` (your-org/nexus-code#1535) is enrolled for the same reason:
# it is reachable as `ng longjob`, it parses fifteen flags, and its `--help`
# is its own header — so the property "every parsed flag is in the help it
# prints" is exactly the one worth keeping true for a tool workers are told
# to reach for from the floor.
_WALKED_FACADES='send.sh
longjob-watch.sh'

_delegated_scripts() {
    {   grep -oE '"\$_script_dir/[a-z-]+\.sh"' "$NG_SRC" | sed 's|.*/||; s|"||'
        printf '%s\n' "$_WALKED_FACADES"
    } | sed '/^$/d' | sort -u
}

# The FULL `ng` argument surface, by BOTH delegation forms — the reference the
# walk above is reconciled against (your-org/nexus-code#943). `_delegated_scripts`
# reads only the `"$_script_dir/…"` form; `ng` also delegates fourteen verbs via
# the one-line `_facade <name>.sh` shape, which that grep cannot see. Kept as a
# SEPARATE function on purpose: an expectation computed by the same expression it
# checks is not a check.
_ng_surface_scripts() {
    {   grep -oE '"\$_script_dir/[a-z0-9-]+\.sh"' "$NG_SRC" | sed 's|.*/||; s|"||'
        grep -oE '_facade[[:space:]]+[a-z0-9-]+\.(sh|py)'   "$NG_SRC" | sed 's|.*[[:space:]]||'
    } | sort -u
}

# --population (your-org/nexus-code#803 protocol, enrolled by #1078).
#
# This guard's subject is the flags `ng` parses AND the flags of every script
# `ng` delegates a verb to — so a diff that ADDS a delegated script is the most
# obviously relevant diff there is, and until now could not select it. `#1065`
# added `monitor/send.sh` as a delegated script, reddened this suite, and this
# suite was neither selected nor named in `CONSIDERED AND EXCLUDED`, because a
# guard that declares no population is invisible to the index rather than
# excluded by it.
#
# Declares the FULL surface via `_ng_surface_scripts`, not the narrower
# `_delegated_scripts` walk. Had it declared the walked subset, `send.sh` would
# have been outside the population at `#1065` time and selection would have
# rested on `monitor/ng` alone — which is the property this enrolment exists to
# provide, so the wider function is the correct one to call.
#
# Calls the guard's OWN enumerator, per the protocol's one rule: a hand-typed
# list of what it currently returns is a second implementation, and a second
# implementation drifts into confidently reporting that this guard does not
# read a file it does read.
#
# Non-existent surface entries are dropped, matching `_delegated_drift`'s own
# `[[ -r "$f" ]] || continue`: `ng` can name a facade whose script is not in
# this tree, and `gp_render` REFUSES a population naming a path that does not
# exist. Dropping here keeps the refusal meaningful (a rotted population) rather
# than making it fire on a condition the guard already tolerates.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    local _d _s
    _d="$(cd "$(dirname "$NG_SRC")" && pwd)"
    printf '%s\n' "$_d/ng"
    while IFS= read -r _s; do
        [[ -n "$_s" ]] || continue
        [[ -e "$_d/$_s" ]] || continue
        printf '%s/%s\n' "$_d" "$_s"
    done < <(_ng_surface_scripts)
}
gp_handle "$@"

# The flags a script parses, by grep/sed — DELIBERATELY NOT the gawk the walk
# below uses. Two predicates over the same file, so a broken anchor in either
# surfaces as a disagreement instead of as two matching silences.
_flags_of() {   # <file>
    grep -oE '^[[:space:]]*--[a-zA-Z0-9|_-]+\)' "$1" \
        | sed 's/^[[:space:]]*//; s/)$//' | tr '|' '\n' | sort -u
}

_delegated_drift() {   # <drift-out> <checked-out> <rows-out>
    local out="$1" cnt="$2" rows="$3" f s parsed usage fl checked=0
    : > "$out"; : > "$rows"
    while IFS= read -r s; do
        f="$(dirname "$NG_SRC")/$s"
        [[ -r "$f" ]] || continue
        # The surface a caller reads: what the script prints for --help and
        # for a bare invocation. Both, because several use one or the other.
        usage=$( { timeout 20 bash "$f" --help; timeout 20 bash "$f"; } 2>&1 </dev/null )
        parsed=$(gawk 'match($0,/^[[:space:]]*(--[a-zA-Z0-9|_-]+)\)/,m){
                          n=split(m[1],a,"|"); for(i=1;i<=n;i++) print a[i] }' "$f" | sort -u)
        while IFS= read -r fl; do
            [[ -n "$fl" ]] || continue
            checked=$(( checked + 1 ))
            printf '%s %s\n' "$s" "$fl" >> "$rows"
            grep -qF -- "$fl" <<<"$usage" || printf 'monitor/%s %s\n' "$s" "$fl" >> "$out"
        done <<<"$parsed"
    done < <(_delegated_scripts)
    printf '%s' "$checked" > "$cnt"
}

echo '=== every parsed flag appears in its verb’s own usage surface ==='

_drifts "$NG_SRC" "$WORK/drift.txt" "$WORK/checked.txt" "$WORK/skipped.txt"
DRIFT=$(<"$WORK/drift.txt"); CHECKED=$(<"$WORK/checked.txt")

# …and the same question of every script `ng` delegates a verb to.
_delegated_drift "$WORK/ddrift.txt" "$WORK/dchecked.txt" "$WORK/drows.txt"
DCHECKED=$(<"$WORK/dchecked.txt")
DRIFT="$DRIFT"$'\n'"$(<"$WORK/ddrift.txt")"
DRIFT=$(sed '/^$/d' <<<"$DRIFT")

# ---- NON-VACUITY, DERIVED (your-org/nexus-code#943) ----------------------
#
# Every verdict below is about a SET DIFFERENCE, and a lookup that matches
# nothing yields an empty difference that reads as success. So the walk has to
# be shown to have happened — and until now that was done with FLOORS:
#
#     (( DELEGATED_N >= 5 && DCHECKED >= 40 ))    # true values: 8 and 89
#     (( CHECKED >= 80 ))                          # true value: 101
#     (( PAIRS   >= 80 ))                          # true value: 102
#
# `DCHECKED >= 40` against a true 89 is 49 of slack, the widest bound in either
# guard file this PR authored. Measured: dropping `request-channel.sh` and
# `pane-state.sh` from the walk removes 38 of 89 flags — **42 % of the
# population, including the script `#906 R1` was about** — leaves 51, and still
# printed "the delegated population was walked" at 9 passed, 0 failed. A bound
# with that much slack is not a bound; it is a sentence that says the walk
# happened.
#
# Same correction as B-REACH-POP in test-ng-flag-order.sh: DERIVE the
# expectation from an independent source and assert EQUALITY. Raising 40 to 89
# would only move the cliff.

# The scripts this guard does NOT walk, recorded rather than silently absent.
# `_delegated_scripts` reads one delegation form; the surface has two, and the
# eleven below are reachable as `ng <verb>` through the one-line `_facade`
# shape. They are OUT because widening the walk adds 43 flags and a drift
# ratchet those flags have never been measured against — a scope decision that
# belongs to whoever takes it, not a blind spot. Recorded here so the next
# reader sees the boundary instead of inferring one, and so the reconciliation
# below FAILS BY NAME the moment a walked script silently leaves the walk.
_D_UNWALKED='ci-head-attempts.sh
declare-no-wait.sh
declare-wait.sh
guards-for-diff.sh
lit.sh
paste-followup.sh
reports-roll.sh
usage-report.py
user-pat.sh
window-session-id.sh
write-probe.sh'

_D_EXPECT=""
while IFS= read -r _s; do
    [[ -n "$_s" ]] || continue
    grep -qxF "$_s" <<<"$_D_UNWALKED" && continue
    _p="$(dirname "$NG_SRC")/$_s"
    [[ -r "$_p" ]] || continue
    while IFS= read -r _fl; do
        [[ -n "$_fl" ]] && _D_EXPECT+="$_s $_fl"$'\n'
    done < <(_flags_of "$_p")
done < <(_ng_surface_scripts)
DELEGATED_N=$(_delegated_scripts | wc -l)
printf '  INFO: delegated walk — %d scripts, %d flags; the surface minus the recorded exclusions parses %d\n' \
    "$DELEGATED_N" "$DCHECKED" "$(printf '%s' "$_D_EXPECT" | grep -c . )"
assert_empty "no flag in the delegated population went UNWALKED" \
    "$(comm -23 <(printf '%s' "$_D_EXPECT" | sort -u) <(sort -u "$WORK/drows.txt"))"
assert_empty "…and the walk covered nothing outside that population" \
    "$(comm -13 <(printf '%s' "$_D_EXPECT" | sort -u) <(sort -u "$WORK/drows.txt"))"

# The same move for the `monitor/ng` half. `CHECKED` and `PAIRS` were two
# floors over one population; the relation between them is exact, so assert it
# instead. `_drifts` SKIPS a pair whose verb has no `_usage_for` arm at all —
# a silent `continue` that the floors hid, and that hides a whole VERB rather
# than a flag. Recording the skipped set makes that visible and ratchets it.
PAIRS=$(wc -l < "$WORK/parsed.tsv")
SKIPPED=$(sed '/^$/d' "$WORK/skipped.txt" | sort -u)
SKIPPED_N=$(printf '%s' "$SKIPPED" | grep -c . )
assert_eq "every parsed pair was either CHECKED or recorded as skipped" \
    "$(( CHECKED + SKIPPED_N ))" "$PAIRS"
# `cmd_skeptic_disposition` parses `--reports-dir` and has NO `_usage_for` arm,
# so no comparison is possible for it — the flag is undiscoverable for the same
# #883 reason the drift rows are, one level up. Recorded, not suppressed: a new
# armless verb joins this list and fails until somebody says why.
assert_eq "…and the skipped set is exactly the recorded one" \
    "$SKIPPED" "cmd_skeptic_disposition --reports-dir"

# ---- every recorded row must carry a REASON ------------------------------
# A bare list of names invites the next reader to make the guard pass by
# pasting the strings into the usage arm — which would be the wrong fix for at
# least three of these (`--skeptic-waive` is operator-only; `--skeptic-decision`
# and `--skeptic-rationale` are a pair). The reason is the part that says
# whether advertising THIS row is yet correct, so a row without one is not a
# record, it is a suppression.
REASONLESS=""
while IFS= read -r row; do
    [[ -n "${row// /}" ]] || continue
    reason="${row#*|}"
    if [[ "$row" != *"|"* || ${#reason} -lt 40 ]]; then
        REASONLESS+="${row%%|*}"$'\n'
    fi
done <<<"$KNOWN_DRIFT_ROWS"
if [[ -z "${REASONLESS//[$'\n' ]/}" ]]; then
    pass "every recorded drift carries a substantive reason"
else
    fail "recorded drift row(s) with no reason (or too short to be one):"
    while IFS= read -r r; do [[ -n "${r// /}" ]] && printf '         %s\n' "$r" >&2; done <<<"$REASONLESS"
    printf '         A row without a reason is a suppression, not a record. Say WHY the flag is\n' >&2
    printf '         held back, so the next reader does not advertise the wrong thing to go green.\n' >&2
fi

# ---- NEW drift: anything not on the known list ---------------------------
NEW=$(comm -23 <(sort <<<"$DRIFT") <(sort <<<"$KNOWN_DRIFT") | sed '/^$/d')
if [[ -z "$NEW" ]]; then
    pass "no NEW parsed-but-unadvertised flag"
else
    fail "flag(s) parsed by a verb and absent from that verb's usage arm (your-org/nexus-code#906 A):"
    while IFS= read -r r; do printf '         %s\n' "$r" >&2; done <<<"$NEW"
    printf '         Add the flag to its `_usage_for` arm. `ng <verb> --help` is the surface a\n' >&2
    printf '         caller reads; a flag absent from it is undiscoverable by construction (#883).\n' >&2
fi

# ---- STALE entries: a recorded drift that is now FIXED --------------------
# This is what makes it a ratchet. Without it the list would be a suppression
# file that silently outlives the defects it names.
STALE=$(comm -13 <(sort <<<"$DRIFT") <(sort <<<"$KNOWN_DRIFT") | sed '/^$/d')
if [[ -z "$STALE" ]]; then
    pass "no stale entries — every recorded drift is still real"
else
    fail "recorded drift(s) that are now FIXED — delete these rows from KNOWN_DRIFT_ROWS:"
    while IFS= read -r r; do
        printf '         %s\n' "$r" >&2
        # Echo the row's reason too: a stale entry means somebody advertised
        # the flag, and the reason says whether that was the right call.
        # Split on the FIRST `|` only: a reason may itself contain pipes
        # (`credible|check|suspect|refuted` does), and an awk -F'|' field
        # split truncates it mid-sentence — measured.
        while IFS= read -r _kr; do
            [[ "${_kr%%|*}" == "$r "* || "${_kr%%|*}" == "$r" ]] || continue
            printf '           was exempt because: %s\n' "$(sed 's/^ *//' <<<"${_kr#*|}")" >&2
            break
        done <<<"$KNOWN_DRIFT_ROWS"
    done <<<"$STALE"
fi

# ---- the guard must be able to SEE a drift ------------------------------
# Three assertions above are absences. Plant one and require detection.
PLANT="$WORK/ng-planted"
cp "$NG_SRC" "$PLANT"
python3 - "$PLANT" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
# a real, advertised flag removed from its usage arm ⇒ a drift appears
a = '        cmd_show)           echo "usage: ng show <comment-id> [--repo <owner/name>] [--meta]" ;;'
b = '        cmd_show)           echo "usage: ng show <comment-id> [--repo <owner/name>]" ;;'
assert s.count(a) == 1, "plant anchor missing/not unique"
open(p, 'w').write(s.replace(a, b, 1))
PY
_drifts "$PLANT" "$WORK/drift2.txt" "$WORK/checked2.txt" "$WORK/skipped2.txt"
PLANTED=$(<"$WORK/drift2.txt")
assert_contains "CONTROL a planted drift is detected" "$PLANTED" 'cmd_show --meta'
# …and the planted file must not ALSO lose the real ones (the probe is stable)
# EXACTLY the planted drift and nothing else. This used to be phrased as
# "…without disturbing the known population" and anchored on a --skeptic-*
# row; those rows were discharged when dev advertised the family, and an
# assertion pinned to a deleted row asserts nothing. The stronger claim is
# available anyway: the planted run covers monitor/ng, whose drift set is now
# EMPTY, so planting one must yield exactly one.
assert_eq "CONTROL …and finds exactly that drift, with no spurious others" \
    "$PLANTED" "cmd_show --meta"

# ---- the top-level surface, for the severity claim ----------------------
# The eleven held-back flags are absent from the PER-VERB arm but present in
# the top-level synopsis. Recording it so the manifest's rationale above is
# checked rather than asserted — and so a future rewrite that drops them from
# BOTH surfaces goes red here.
TOP=$(bash "$NG_SRC" --help 2>/dev/null || true)
assert_contains "the skeptic family IS on the top-level ng --help" "$TOP" '--skeptic-verdict'

# ---- the floors this file declares must BE the floors it contains ---------
# The declaration is otherwise a comment that rots the first time somebody adds
# a bound, which is exactly how #943's instance here survived: the sibling
# guard declared its own six and nobody looked next door.
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
    # source. Measured — it captured prose from the function below and reported
    # `expectation matches` as a declared bound.
    local _m="BOUND-INVENTORY"
    sed -n "/BEGIN $_m/,/END $_m/p" "$1" \
        | gawk 'match($0,/^#[[:space:]]+([A-Za-z_][A-Za-z_0-9]*)([[:space:]]|$)/,m){print m[1]}' | sort -u
}
_SELF="$_test_dir/$(basename "${BASH_SOURCE[0]}")"
assert_eq "every population floor in this file is declared in its inventory" \
    "$(_bound_names "$_SELF" | tr '\n' ' ')" "$(_declared_bounds "$_SELF" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, ledger=yes level).
#   2  the DELEGATED population, reconciled both ways against a derived
#      expectation (#943 — was a `DCHECKED >= 40` floor over a true 89)
# + 2  the monitor/ng half: checked + skipped == parsed, and the skipped set
#      matches its recorded manifest (was two more floors)
# + 1  every recorded row carries a reason
# + 2  new drift, stale entries
# + 2  the planted-drift control
# + 1  the top-level surface
# + 1  the bound inventory is complete
EXPECTED=$(( 2 + 2 + 1 + 2 + 2 + 1 + 1 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
