#!/usr/bin/env bash
# Argument-loop progress guard (your-org/nexus-code#924).
#
# Run: bash monitor/watcher/test-argloop-progress-guard.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT. A value-taking flag given LAST has no value to consume. `shift 2`
# with `$#` == 1 is REFUSED — bash shifts nothing and returns non-zero — so `$#`
# never decreases, the case arm re-matches the same `$1`, and the loop SPINS
# FOREVER. Measured on `origin/main`, so it predates the verbs that surfaced it.
#
# WHY IT IS WORSE THAN AN ERROR, which is why this suite exists at all: the
# agent waits, the orchestrator reads the window as `busy`, and NOTHING
# surfaces it. There is no timeout and no diagnostic. A window spinning inside
# `ng` — the tool every agent uses for every GitHub write — is indistinguishable
# from one doing real work.
#
# EVERY INVOCATION HERE IS BOUNDED BY `timeout`. A test for an infinite loop
# that is not bounded is the same defect wearing a test's clothes, and an
# unbounded repro on this board is another wedged window. `rc 124` is the
# timeout's own signal and this suite treats it as a FAILURE everywhere.
#
# THE SIZE OF THE HAZARD, because it is the argument for the fix's shape.
# The first evidence for this change was EIGHT reproduced hangs. Eight is a
# CASE SET, not a population. Derived at `e256d4a` over the `ng` dispatch
# surface, with the predicate `shift 2`, no `||` handler, value read as
# `${2:-}`, in a file that does NOT `set -e`:
#
#     ref e256d4a   ng 74 · guards-for-diff.sh 3 · ci-head-attempts.sh 1
#                   reports-roll.sh 1                        -> 79 sites
#
# `#952`'s second reviewer derived 77 from the same stated predicate; the
# two-site difference inside `monitor/ng` is unresolved and neither of us has
# reconciled the other's list. Both are ~10x the eight, which is the claim that
# matters: this is a systemic hazard, not a tidy defect.
#
# THREE PROTECTIONS make the number smaller than the 113 unguarded `shift 2`
# sites, and missing any of them inflates it: an `||` handler; reading `"$2"`
# BARE, which aborts under `set -u` instead of spinning; and `set -e` in the
# file, which exits on the failed shift. `pane-state.sh` (16), `upload-asset.sh`
# (5) and `lit.sh` (3) drop out entirely for those reasons.
#
# AND THE FIX DOES NOT DEPEND ON THAT NUMBER. It is STRUCTURAL: the invariant
# covers every argument loop because of HOW it works, not because 79 sites were
# enumerated and patched. That is the whole case for the loop invariant over
# 113 individual guards — a per-site fix would have covered exactly the sites
# somebody thought to look at, and the count above is evidence that nobody
# would have looked at all of them.
#
# WHAT IS PINNED, and why it is the population rather than the instances:
# §1 drives real verbs and asserts they refuse rather than spin. §3 asserts the
# INVARIANT holds across every argument loop the `ng` verbs expose — because
# the fix is structural, and the thing that can regress is a NEW loop written
# in a spelling nobody guarded. That is not hypothetical: this suite's own
# author enumerated the population with a regex assuming `while (( $# > 0 ))`,
# got 60, and MISSED TWO loops spelled `while (( $# ))` — both of which hung.
# §3 therefore matches on `$#` alone and never on a spelling.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
cd "$REPO_ROOT" || { echo "FAIL: cd repo root"; exit 1; }

# ── PIN THE STATE DIR (your-org/nexus-code#1336, #1349) ────────────────────
#
# This suite runs the real `ng` fourteen times (`./monitor/ng react …`, `issue
# create …`, …) to assert that a trailing value-taking flag REFUSES rather than
# spins. Every one of those resolves a state directory through a FOUR-arm chain
# in which only arm 1 is unconditional:
#
#   1. $NEXUS_STATE_DIR                     <- the only arm that cannot be fallen past
#   2. $NEXUS_ROOT/monitor/.state
#   3. config nexus.root + /monitor/.state  <- the arm nobody accounts for
#   4. $_script_dir/.state
#
# Unsetting `NEXUS_ROOT` does not end the search, it ADVANCES it to arm 3 —
# which on an operator's primary IS the primary. Measured before this pin
# (`#1336`): verdict LEAK, rc 0, `30 passed, 0 failed`, FOUR paths written into
# the inherited root — `monitor/.state/ng-usage.jsonl` and three under
# `monitor/.state/gh-capable.d/`. **SENSITIVE BUT GREEN** is the shape: the
# suite passes while writing into the operator's canonical state on every local
# run.
#
# `fixture_suites()` cannot see this suite: its NG arm greps four spellings and
# this one uses a FIFTH — a bare relative `./monitor/ng` in command position,
# with no `NG=` assignment, no `cp`, and no double quote after `ng`. So the CI
# gate never selected it, which is why this went unnoticed. Pinning arm 1 is
# correct whether or not that predicate is ever widened, and does not depend on
# a spelling.
_ARGLOOP_STATE=$(mktemp -d -t nexus-argloop-state-XXXXXX)
trap 'rm -rf "$_ARGLOOP_STATE"' EXIT
# `th_pin_ng_state` rather than a bare export (your-org/nexus-code#1306, landed
# on dev after this branch was cut): it pins arm 1 AND PROVES the pin in both
# directions -- it aborts if a probe row reached a decoy root, and equally if no
# row was written at all, so an UNVERIFIED pin cannot pass as a clean one. A
# bare `export` is the same instruction with no evidence, which is the shape
# this whole class is about. This suite sources `_test_helpers.sh`, which is the
# documented precondition (a suite that does not gets rc 127 and a green
# summary that still leaks).
th_pin_ng_state "$REPO_ROOT/monitor/ng" "$_ARGLOOP_STATE"
# AND A SECOND RESOLVER, WHICH `NEXUS_STATE_DIR` DOES NOT GOVERN. Pinning arm 1
# above closed `ng-usage.jsonl` and left `monitor/.state/gh-capable.d/` still
# leaking, because `monitor/gh-capable.sh:_ghc_cache_dir` is an INDEPENDENT
# chain — `NEXUS_GH_CAPABLE_CACHE`, else `$NEXUS_ROOT/monitor/.state/gh-capable.d`
# — and it never consults `NEXUS_STATE_DIR`. So "pin the state dir" is one
# resolver's answer, not the tree's: two resolvers, two override variables, and
# the documented isolation knob governs only one of them. Measured here, which
# is the only reason it is pinned rather than assumed.
export NEXUS_GH_CAPABLE_CACHE="$_ARGLOOP_STATE/gh-capable.d"

# Assertions go through the shared LEDGER (`_th_pass`/`_th_fail` +
# `th_summary_and_exit`), not a hand-rolled tally: a suite that counts its own
# passes can lose a failure in a subshell and still announce a green, which is
# what `summary-honesty.manifest` exists to stop. This suite is fully protected
# — ledger=yes AND count=exact — rather than manifest-listed.
ok()   { printf '  PASS: %s\n' "$1"; _th_pass; }
bad()  { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
eq()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 — got '$2', want '$3'"; }

# The whole population: `monitor/ng` plus every script it delegates a verb to
# (your-org/nexus-code#911 — the population is the VERBS `ng` exposes, not the
# lines `monitor/ng` contains).
#
# DERIVED, NOT HARDCODED, and that distinction is a finding this suite earned.
# The first revision listed 13 scripts by hand. `ng` dispatches through
# `_facade <script>` and `"$_script_dir/<script>"`, and the hand list MISSED TWO
# — `mint-token.sh` (`ng token`) and `write-probe.sh` (`ng write-probe`). Both
# were unguarded. A planted `shift 2` in `write-probe.sh` hung the verb while
# this suite reported 15/0: the guard against drift could not see the scripts it
# claimed to cover. Deriving from the dispatch sites means the 16th script
# enters the population the moment `ng` learns to call it, with no edit here.
_derive_pop() {
    {   printf 'ng\n'
        grep -oE '_facade [a-z0-9_-]+\.sh' "$REPO_ROOT/monitor/ng" | awk '{print $2}'
        grep -oE '\$_script_dir/[a-z0-9_-]+\.sh' "$REPO_ROOT/monitor/ng" | sed 's|.*/||'
    } | sort -u
}
POP=()
while IFS= read -r _p; do [[ -n "$_p" && -f "monitor/$_p" ]] && POP+=("$_p"); done < <(_derive_pop)

# The §3b corpus, EXTRACTED INTO A FUNCTION so `gp_population` below can CALL
# it rather than restate it (your-org/nexus-code#803's one rule for an
# implementor: a copy is a second implementation, and a second implementation
# drifts). §3b invokes exactly this.
#
# THE FULL LIST, NOT THE `grep -l` NARROWING, is what this guard READS: §3b
# greps every one of these files for the backstop message, so their bytes are
# in its read set and the narrowing to matches is a speed optimisation. That is
# the `test-spawn-shape-manifest.sh` precedent ("every tracked file, because the
# classifier greps them all — the narrowing to matches is a speed optimisation,
# not the read set"), and it is also the only form that is APPLICABILITY-keyed:
# a population of "files that already carry the message" is CONFORMANCE-keyed,
# so renaming the message would remove the file from the population and
# DESELECT this guard for exactly the edit it exists to catch (#1197, #1224).
_argloop_backstop_corpus() {
    ( cd "$REPO_ROOT" && git ls-files -- ':(glob)**/*.sh' ':(glob)*.sh' 'monitor/ng' )
}

# ---- the `--population` protocol (your-org/nexus-code#803, #1301) ----------
#
# THIS GUARD'S POPULATION IS "essentially every shell file", which is exactly
# why declaring it feels redundant and exactly why it matters: an edit ANYWHERE
# can join it. Undeclared, this suite is INVISIBLE to `ng guards-for-diff` —
# absent from SELECTED and from CONSIDERED AND EXCLUDED alike — so exit 0 from
# that tool says nothing about it (#1078).
#
# BOTH ARMS, because the suite scans both: `_derive_pop` is the `ng`-dispatch
# surface §1/§2/§3/§3c drive, and `_argloop_backstop_corpus` is the repo-wide
# shell corpus §3b greps. The first is a subset of the second on this tree; it
# is declared anyway because the two enumerators can move independently, and a
# population that is only accidentally complete is not declared.
#
# PLACED HERE — above §1, not merely above the first scan — because `gp_handle`
# EXITS when it handles the flag, so anything printed before it lands in the
# probe's STDOUT and is read as a population row (measured on
# test-sigpipe-assertion-lint.sh: four lines of section-1 output ahead of 615
# real rows, all four refused by `gp_render` as paths that do not exist).
. "$_test_dir/../_guard_population.sh"
gp_population() {
    _derive_pop | while IFS= read -r _p; do
        [[ -n "$_p" && -f "$REPO_ROOT/monitor/$_p" ]] && printf 'monitor/%s\n' "$_p"
    done
    _argloop_backstop_corpus
}
gp_handle "$@"

# ---- §1 the defect: a trailing value-taking flag REFUSES, never spins -------
echo '=== 1. a value-taking flag given last errors loudly instead of hanging ==='

# rc 124 is `timeout`'s signal. Asserting "not 124" is the load-bearing half;
# asserting 64 pins the diagnostic exit we chose.
_rc() { timeout 8 "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# TWO MECHANISMS NOW CLOSE `#924`, AND THEY RETURN DIFFERENT EXIT CODES.
# Recorded at the B1 bundle seam, because the rows below stop being a uniform
# "expect 64" the moment your-org/nexus-code#903 is in the same tree:
#
#   #903  `_need_val <flag> "$#" "${2:-}"` — a PER-SITE arity+emptiness guard
#         inside the arm. Fires FIRST (the loop invariant is only consulted on
#         the NEXT iteration), names the flag, and exits 1 via `ng`'s `die`.
#   #924  `_argloop_stuck` — the STRUCTURAL loop invariant. Exits 64.
#
# Measured on the merged tree: of 73 value-taking arms in `monitor/ng`, 71
# carry `_need_val` and the other 2 (`cmd_respawn`'s --window/--workdir) carry
# their own inline `[[ -n "${2:-}" ]] || die`. So inside `monitor/ng` there is
# no longer a reachable path to `_argloop_stuck` — it is a BACKSTOP for the
# next arm somebody writes unguarded, which is exactly the role #924 argued an
# invariant should play over 113 per-site guards. #903 never touched
# guards-for-diff.sh or ci-head-attempts.sh, so there the invariant is still
# the live mechanism.
#
# The rows therefore pin WHICH MECHANISM OWNS WHICH SURFACE rather than a
# single number. That is a tighter assertion than the original, not a weaker
# one: `eq ... "1"` implies "not 124" (the load-bearing half) and additionally
# fails if #903's per-site guard is ever removed from these arms.
#
# RESOLVED (your-org/nexus-code#990). One user-visible condition — a flag given
# no value — used to yield rc 1 from `ng` (#903's `_need_val`) and rc 64 from
# the delegated scripts (#924's `_argloop_stuck`), so a caller testing
# `rc == 64` to detect its own malformed call was right about one surface and
# wrong about the other.
#
# Unified on 64 = EX_USAGE, and the choice was not a coin flip: at 7c4ddbb
# `_argloop_stuck` is defined in SIXTEEN scripts and every one exits 64, so
# `ng`'s `_need_val` was the lone outlier. #990 frames the split as
# "guards-for-diff/ci-head-attempts vs ng", which understates it — those two
# are a sample of the sixteen, not the population. Aligning one helper with
# sixteen scripts beats rewriting sixteen to match one.
eq "ng react --repo with no value refuses with EX_USAGE (#990)" \
    "$(_rc ./monitor/ng react 1 rocket --repo)" "64"
eq "ng issue create --title with no value refuses with EX_USAGE (#990)" \
    "$(_rc ./monitor/ng issue create --title)"  "64"
eq "ng wrap-up --repo with no value refuses with EX_USAGE (#990)" \
    "$(_rc ./monitor/ng wrap-up 1 /tmp/x.md --repo)" "64"
eq "guards-for-diff.sh --base with no value refuses (#924 invariant owns this)" \
    "$(_rc ./monitor/guards-for-diff.sh --base)" "64"
eq "ci-head-attempts.sh --repo with no value refuses (#924 invariant owns this)" \
    "$(_rc ./monitor/ci-head-attempts.sh --repo)" "64"

# The diagnostic must NAME the offending option — a bare "usage" would leave the
# agent to guess which of its flags was short.
msg=$(timeout 8 ./monitor/ng react 1 rocket --repo 2>&1 | tail -1)
case "$msg" in
    *--repo*requires\ a\ value*) ok "the refusal names the offending option" ;;
    *) bad "the refusal does not name the option — got: $msg" ;;
esac

# ---- §2 controls: the guard must not fire on well-formed input --------------
# A guard that refuses everything is a guard that gets removed.
echo '=== 2. CONTROLS: well-formed invocations are untouched ==='
rc=$(_rc ./monitor/ng react 1 rocket --repo your-org/nexus-code)
[[ "$rc" != "64" && "$rc" != "124" ]] && ok "the same flag WITH a value does not trip the guard (rc $rc)" \
                                      || bad "flag with a value tripped the guard or hung — rc $rc"
eq "ng --help still exits 0"            "$(_rc ./monitor/ng --help)"            "0"
eq "ng report-grep --help still exits 0" "$(_rc ./monitor/ng report-grep --help)" "0"

# A VALUELESS flag given LAST must still parse. This is the arm the guard could
# most plausibly break: it shifts by ONE, so a naive "did the flag get a value"
# check would reject it. The guard keys on PROGRESS, not on arity, so it must
# not fire — the verb may still fail for its own reasons, just never 64 or 124.
vrc=$(_rc ./monitor/ng report-check /tmp/no-such-report.md --allow-todo)
[[ "$vrc" != "64" && "$vrc" != "124" ]] \
    && ok "a VALUELESS flag given last still parses (rc $vrc, not 64/124)" \
    || bad "a valueless flag tripped the guard or hung — rc $vrc"

# ---- §3 the population invariant -------------------------------------------
# THE STRUCTURAL ASSERTION. Matching on `$#` alone, never on a loop spelling:
# the author's first enumeration assumed `while (( $# > 0 ))`, returned 60, and
# missed two `while (( $# ))` loops that both hung.
#
# KEYED ON THE LOOP BODY, NOT ON A LITERAL ON THE `while` LINE
# (your-org/nexus-code#1160 D1+D2). The header above has always claimed §3
# "matches on `$#` alone and never on a spelling". That was true of the `$#`
# half and FALSE of the guard half: the classifier was a TEXT GLOB
# (`*_argloop_prev_[0-9]*=-1*`) over the `while` line, and the enumeration
# regex only admitted the prefix `_argloop_prev_<digits>=-1; `. Both halves of
# that were measured broken at 989b888:
#
#   * FALSE POSITIVE. A loop that IS guarded — same comparison, same handler,
#     same decrement — but spelled over two lines with a non-numeric suffix was
#     reported `unguarded`, which is a claim about a PROPERTY (an unbounded
#     loop, a hang hazard) made on the strength of a PROXY (house spelling).
#     Driven across 40 input classes it produced zero `rc 124`, with a firing
#     potency control. That red stood on `dev` for weeks and was silenced by a
#     SEMANTICS-PRESERVING rename+join.
#   * FALSE NEGATIVE, which is the half that matters. Delete a real backstop
#     but leave the literal `_argloop_prev_11=-1` on the `while` line and the
#     old §3 stayed GREEN at 29/0 while `ng skeptic-disposition w --noop` went
#     from `rc 64` to `rc 124` — a live hang, invisible.
#   * AND THE POPULATION WAS SHORT BY ONE. `monitor/send.sh:169` is a guarded
#     loop in a third spelling (`_prev=-1; while …`), which the enumeration
#     regex could not even see. Making its guard inert (`_prev=$(( _prev - 1 ))`)
#     left §3 green at 29/0 while `send.sh w --noop` went 64 -> 124.
#
# One fix closes both, and it is the one #1160 proposes: classify on the loop
# BODY — a `$#`-vs-previous comparison, with a handler, and a `V=$#` progress
# record, ALL BEFORE THE FIRST `shift`. That is the property the guard actually
# has. It is invariant under rename, under line-joining, and under any prefix
# spelling, and it cannot be satisfied by a decorative literal.
echo '=== 3. every argument loop in the ng-verb population is guarded ==='

# THE CLASSIFIER. Its enumeration admits ANY assignment prefix, not just
# `_argloop_prev_N=-1; `. Measured at 989b888 over the 25 derived dispatch
# targets: the old regex found 72, this one finds 73, and a maximally loose
# `(while|until).*\$#` also finds 73 — so this is the whole population, not a
# wider guess. For each loop line, build the region from the loop line up to
# (and excluding) the first `shift`, then require, in that region:
#   (1) a comparison of `$#` against a variable V  — `(( $# != V ))`,
#       `(( V != $# ))`, `[[ $# -ne V ]]`, either order;
#   (2) a `||` (or `&&`-negated) handler on that comparison; and
#   (3) the progress record `V=$#` for the SAME V.
# (3) is what kills the inert-guard mutant: `_prev=$(( _prev - 1 ))` keeps the
# comparison and the handler and still never fires. (1)+(2) are what kill the
# deleted-backstop mutant that keeps the literal on the `while` line.
_argloop_classify() {  # <file> -> "<lineno>\t<GUARDED|UNGUARDED>\t<text>" per loop
    awk '
    { src[NR] = $0 }
    END {
      for (n = 1; n <= NR; n++) {
        line = src[n]
        if (line ~ /^[[:space:]]*#/) continue
        if (line !~ /^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^;]*; )*while[^#]*\$#/) continue
        region = line
        for (m = n + 1; m <= NR && m <= n + 25; m++) {
          nxt = src[m]
          if (nxt ~ /(^|[^[:alnum:]_])shift([^[:alnum:]_]|$)/) break
          if (nxt ~ /(^|[^[:alnum:]_])(done|esac)([^[:alnum:]_]|$)/) break
          region = region "\n" nxt
        }
        v = ""
        if (match(region, /\$#[[:space:]]*(!=|-ne)[[:space:]]*\$?[A-Za-z_][A-Za-z0-9_]*/)) {
          t = substr(region, RSTART, RLENGTH); sub(/^\$#[[:space:]]*(!=|-ne)[[:space:]]*\$?/, "", t); v = t
        } else if (match(region, /\$?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(!=|-ne)[[:space:]]*\$#/)) {
          t = substr(region, RSTART, RLENGTH); sub(/[[:space:]]*(!=|-ne)[[:space:]]*\$#$/, "", t); sub(/^\$/, "", t); v = t
        }
        ok = 0; h = ""
        if (v != "" && region ~ /(\|\||&&)/) {
          # the progress record, for the SAME variable
          re = "(^|[^[:alnum:]_])" v "=\"?\\$#"
          if (region ~ re) ok = 1
        }
        # the HANDLER the guard calls — the name that must be defined in THIS
        # file (#646: no shared-source dependency), keyed on what the guard
        # actually calls rather than on the literal name `_argloop_stuck`.
        if (ok && match(region, /\|\|[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)) {
          h = substr(region, RSTART, RLENGTH); sub(/^\|\|[[:space:]]*/, "", h)
        }
        # SENTINEL FOR THE EMPTY HANDLER FIELD, and it is not cosmetic. TAB is IFS
        # WHITESPACE, so bash `read` COLLAPSES a run of them: emitting an empty `h`
        # puts two adjacent tabs on the wire and the reader below silently shifts
        # `line` into `_handler`, leaving `_text` EMPTY. Measured at 5bd6d400: the
        # one real offender printed as `monitor/ng:7309: ` with NO text — a lint
        # that names its offenders, defeated by its own reporting path. Worse, a
        # GUARDED loop whose handler extraction returns "" (an `&&`-negated guard
        # with no `||`) hands the LOOP TEXT to the handler-definition check below,
        # which then reds naming a function nobody wrote. `-` is unambiguous: no
        # shell function name can be `-`, so the reader can map it back to empty.
        printf "%d\t%s\t%s\t%s\n", n, (ok ? "GUARDED" : "UNGUARDED"), (h == "" ? "-" : h), line
      }
    }' "$1"
}

total=0; guarded=0; unguarded_list=""; _handlers=""; _blind=""
for f in "${POP[@]}"; do
    p="monitor/$f"
    [[ -f "$p" ]] || { bad "population file missing: $p"; continue; }
    _seen=0
    while IFS=$'\t' read -r _ln _verdict _handler _text; do
        [[ -n "$_verdict" ]] || continue
        [[ "$_handler" == "-" ]] && _handler=""
        total=$(( total + 1 )); _seen=$(( _seen + 1 ))
        if [[ "$_verdict" == GUARDED ]]; then
            guarded=$(( guarded + 1 ))
            [[ -n "$_handler" ]] && _handlers="${_handlers}${f}"$'\t'"${_handler}"$'\n'
        else
            unguarded_list="${unguarded_list}${p}:${_ln}: ${_text}"$'\n'
        fi
    done < <(_argloop_classify "$p")
    # THE BLIND-SPOT RATCHET (#1160 D2). A classifier that cannot SEE a loop
    # reports it neither guarded nor unguarded — it vanishes, and the green
    # reads as a clean population rather than an unexamined one. That is how
    # `monitor/send.sh:169` sat outside this section entirely while its guard
    # could be made inert without moving a single assertion. The floors below
    # (`total >= 60`) cannot catch a ONE-loop gap. So cross-check the
    # enumeration against a maximally loose independent scan, per file: any
    # divergence is a spelling this classifier cannot parse, and it reds here
    # instead of disappearing.
    _loose=$(grep -cE '(while|until)[^#]*\$#' "$p" || true)
    (( _seen == _loose )) || _blind="${_blind} ${p}(saw:${_seen} loose:${_loose})"
done

# NON-VACUITY, on BOTH axes. A botched derivation returning no scripts, or a
# botched scan returning no loops, would each satisfy "no unguarded loops" by
# having nothing to check — #618's shape, and the exact way the hardcoded list
# failed silently.
(( ${#POP[@]} >= 14 )) && ok "the population DERIVED ${#POP[@]} dispatch targets" \
                       || bad "derivation returned ${#POP[@]} scripts (expected >=14) — the derivation is blind"
# The two the hand-written list missed must be present, by name. A derivation
# that silently stopped finding them would otherwise look identical to one that
# never had to.
_missed=""
# `printf -v` into a variable, then a herestring — NOT `printf … | grep -qx`.
# `mint-token.sh` sorts 7th of 22, so fifteen writes follow the match; grep -q
# exits at it, the writer takes SIGPIPE and `set -o pipefail` (line 59) promotes
# 141 to the pipeline. The `||` then fires and this guard reports that the
# derivation cannot see `mint-token.sh` — a blindness guard reporting itself
# blind, which is the your-org/nexus-code#598 shape verbatim. Measured 5/2000
# under load; `run-tests.sh --jobs 4` reaches that contention normally.
# `printf -v` over `<<<"$(printf …)"`: command substitution strips trailing
# newlines, so the latter loses a final EMPTY element and diverges on an empty
# needle. Unreachable here (the needles are literals) but the boundary is real.
printf -v _pop_lines '%s\n' "${POP[@]}"
for _w in mint-token.sh write-probe.sh; do
    grep -qx "$_w" <<<"$_pop_lines" || _missed="$_missed $_w"
done
eq "…including the two the hardcoded list omitted" "${_missed:-none}" "none"
(( total >= 60 )) && ok "the population enumerated $total argument loop(s)" \
                  || bad "enumeration returned $total loops (expected >=60) — the scan is blind"
eq "no argument loop is INVISIBLE to the classifier (a spelling it cannot parse)" \
   "${_blind:-none}" "none"
eq "every enumerated loop carries the progress guard" "$(( total - guarded ))" "0"
[[ -z "$unguarded_list" ]] || printf '  unguarded:\n%s' "$unguarded_list" >&2

# Each population file must define the helper it calls, rather than depending on
# a shared source. A new mandatory `source` across 13 scripts turns one absent
# optional file into a total outage (the #646 lesson).
# Scoped to files that actually HAVE a guarded loop — a dispatch target with no
# argument loop needs no helper, and demanding one would make this assertion
# fail for a reason that is not a defect.
# KEYED ON THE HANDLER THE GUARD ACTUALLY CALLS, not on the literal name
# `_argloop_stuck` (#1160 D2). The old form scoped itself with the same
# spelling glob as the classifier above, so a file whose guard is spelled
# differently — `monitor/send.sh`, whose handler is a one-liner named `_stuck`
# implementing the identical contract, as §3b's own header records — was
# excluded from this check rather than passing it. The property is "the
# handler this loop calls is defined in this same file"; the name is incidental.
missing=""
while IFS=$'\t' read -r f h; do
    [[ -n "$f" && -n "$h" ]] || continue
    grep -qE "(^|[^[:alnum:]_])${h}[[:space:]]*\\(\\)" "monitor/$f" \
        || missing="$missing $f($h)"
done < <(printf '%s' "$_handlers" | sort -u)
eq "every population file defines the handler its guard calls (no shared-source dependency)" \
   "${missing:-none}" "none"

# ---- §3b ONE CONDITION, ONE EXIT CODE (your-org/nexus-code#990) -------------
# The ratchet that catches a FOURTH site adopting the other convention.
#
# #990 was possible because nothing checked that the repo agreed with itself:
# `ng` said rc 1 and sixteen delegated scripts said rc 64 for the same
# user-visible condition, and both were "correct" in isolation for two years.
# A new script can reintroduce the split by copying the wrong neighbour, and no
# existing assertion here would notice — §3 above checks that the helper is
# DEFINED, never what it RETURNS.
#
# COVERAGE BOUNDARY, ON THE AXIS THE CONDITION VARIES ON (#1135 skeptic F5).
# This checks every emitter of ONE MESSAGE. It is NOT a check that "a valueless
# flag has one exit code repo-wide", and the difference matters because the
# first draft of this boundary named three other conventions and MISSED one.
# Measured at 7c4ddbb, a value-taking flag given last:
#
#   ./monitor/ng issue create --title        -> 64   (the seventeen)
#   ./monitor/guards-for-diff.sh --base      -> 64
#   ./monitor/watcher/launcher.sh --target   ->  2   <- absent from that draft
#   ./monitor/spawn-worker.sh --model        ->  5
#   ./monitor/lit.sh search foo --limit      ->  1   (bare "$2" under set -u)
#   ./monitor/pane-state.sh --fixture        ->  1   (same)
#
# So the CONDITION still has FOUR codes; #990 unified the largest family, not
# the condition. The two rc-1 cases are the sharpest residual: they read `"$2"`
# bare under `set -u`, so the argument-loop guard is never reached at all and
# the user gets a bash-internal "unbound variable" naming a LINE NUMBER rather
# than a flag. Widening this check to those would assert a unification nobody
# has made; it is recorded here instead so the next reader does not mistake
# this guard's green for the wider claim.
#
# THE POPULATION IS EVERY EMITTER IN THE REPO, not the ng-verb set. A usage
# helper in a script `ng` does not dispatch to still hands a caller the wrong
# code, and scoping this to POP would leave exactly the sites nobody is looking
# at. Enumerated with `:(glob)` — git matches pathspecs with `fnmatch` WITHOUT
# `FNM_PATHNAME`, so a bare `monitor/*.sh` crosses `/` (#1111, #954).
#
# KEYED ON THE EMITTED MESSAGE, NOT ON THE FUNCTION NAME, and that is the whole
# design of this check. The first cut keyed on `^_argloop_stuck()` and returned
# SIXTEEN. The true population is SEVENTEEN: `monitor/send.sh:168` implements
# the identical contract — same message, same `exit 64` — in a one-liner named
# `_stuck`. A name-keyed sweep cannot see it, and it is precisely a renamed or
# hand-rolled copy that is most likely to pick the wrong code. So the key is
# the thing the USER sees, which is what the contract is actually about.
#
# It also has to survive both spellings: a multi-line body where `exit` is two
# lines below the message, and send.sh's one-liner where it is on the same
# line. Hence "first `exit N` at or after the emitting line" rather than an
# anchored function match or a fixed `grep -A` window.
#
# Requiring `printf`/`echo` on the matching line keeps PROSE out: this very
# file discusses the message in the comment block above, and a mention is not
# an implementation. Measured at 7c4ddbb: 17 emitters, 0 prose-only matches.
echo '=== 3b. every argument-loop BACKSTOP in the repo returns EX_USAGE (64) ==='
wrong=""; n_defs=0
while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    # EVERY EMITTER IN THE FILE, NOT THE FIRST (your-org/nexus-code#1160 D3).
    # This read `grep -nEm1` — ONE MATCH PER FILE. `monitor/ng` already matches
    # at :297, so `-m1` stopped there and a hand-rolled second backstop 6,000
    # lines further down was never examined. Measured at 989b888: a planted
    # `_argloop_stuck_sko()` emitting this exact message and returning `exit 1`
    # left this section at 17 emitters and the whole suite at 29/0. That is the
    # precise scenario this section's header names as its reason for existing —
    # "it is precisely a renamed or hand-rolled copy that is most likely to
    # pick the wrong code" — and `-m1` made this the one file where a copy
    # cannot be seen, because the canonical definition shields it.
    #
    # `-m1` WAS HERE FOR A REAL REASON AND IT IS NOT LOST — read this before
    # putting it back. The #622 hazard is `grep … | head -1`: `head` closes the
    # pipe once it has its line, SIGPIPEs `grep`, and `pipefail` promotes 141
    # to the pipeline, whose next reader inverts the verdict. `-m1` stops grep
    # itself, so there is no pipe and no signal — and that was the right call
    # when the reader took one line. There is no `head` and no pipe below: grep
    # writes its FULL output into a process substitution that the `while`
    # drains to EOF, so the truncating reader does not exist and there is
    # nothing for `-m1` to protect. Dropping it removes a blind spot without
    # adding a signal. The #622 ratchet (test-early-exit-reader-manifest.sh)
    # is keyed on the truncating READER, not on the absence of `-m1`.
    while IFS= read -r emit; do
        [[ -n "$emit" ]] || continue
        n_defs=$(( n_defs + 1 ))
        code=$(awk -v s="${emit%%:*}" \
                 'NR>=s && /exit [0-9]+/ { match($0, /exit [0-9]+/); print substr($0, RSTART+5, RLENGTH-5); exit }' "$f")
        [[ "$code" == 64 ]] || wrong="$wrong $f:${emit%%:*}(${code:-none})"
    done < <(grep -nE '(printf|echo)[^#]*argument loop made no progress' "$f")
done < <(_argloop_backstop_corpus \
             | xargs -r grep -l 'argument loop made no progress' 2>/dev/null)

# A FLOOR, because an enumeration that silently returned nothing would pass
# this vacuously — the exact defect class this repo keeps re-learning. 17 at
# 7c4ddbb; the floor is deliberately below that so ordinary churn does not
# break it, but far above zero.
(( n_defs >= 14 )) && ok "the repo enumerated $n_defs argument-loop usage emitter(s)" \
    || bad "only $n_defs argument-loop usage emitter(s) enumerated — the scan went blind"
# WHAT THIS CERTIFIES, STATED EXACTLY (your-org/nexus-code#1135 skeptic F5').
# It used to read "so one condition has one code". That was TRUE OF THE SOURCE
# LITERAL and FALSE OF BEHAVIOUR, and the distinction is the whole of #990.
#
# `_argloop_stuck` is a LOOP-INVARIANT BACKSTOP: it fires only when an
# iteration consumed no argument. Most arms guard themselves FIRST — `shift 2
# || die`, `_need_val`, a bare `"$2"` under `set -u` — so the arm answers and
# the backstop is never consulted. The line this scan reads is therefore not
# the line most users reach. Measured at 7c4ddbb, each script given a
# value-taking flag with no value:
#
#   reaches the backstop (rc 64): guards-for-diff.sh --base,
#                                 ci-head-attempts.sh --repo,
#                                 reports-roll.sh --reports-dir
#   64 by ANOTHER mechanism:      ng (its `_need_val` arm guard, #990)
#   pre-empted by their own arm:  send.sh 1, request-channel.sh 1,
#                                 skeptic-channel.sh 1, obligations.sh 1,
#                                 lit.sh 1, mint-token.sh 1, user-pat.sh 1,
#                                 retire-preflight.sh 2, write-probe.sh 2
#   never reached (`set -u`):     upload-asset.sh 1, pane-state.sh 1
#   not probed (touch the live board / enrolment): paste-followup.sh,
#                                 remote-enroll.sh
#
# So this assertion's honest claim is the narrow one: EVERY BACKSTOP THAT
# EXISTS RETURNS 64. That is a real invariant and worth ratcheting — it stops a
# new script writing `exit 1` into the backstop — but it is NOT "one condition,
# one code", and #990's condition still has four codes repo-wide.
eq "every argument-loop BACKSTOP returns 64 — a source invariant, NOT a claim about what users reach" \
   "${wrong:-none}" "none"

# THE BEHAVIOURAL HALF, because the source check above cannot make it.
# A literal is not an exit code: the first version of this section shipped a
# mutation witness on `monitor/send.sh` — the very file whose discovery
# justified the message-keyed design — and send.sh returns **1**, not 64, for
# a valueless flag. The witness proved the ratchet reads a line no user can
# reach. These four drive the scripts and read the status, so they cannot.
# All four fail during ARGUMENT PARSING, before any action.
echo '=== 3c. the scripts that DO answer a valueless flag with EX_USAGE, driven ==='
eq "behaviour: guards-for-diff.sh --base"      "$(_rc ./monitor/guards-for-diff.sh --base)"        "64"
eq "behaviour: ci-head-attempts.sh --repo"     "$(_rc ./monitor/ci-head-attempts.sh --repo)"       "64"
eq "behaviour: reports-roll.sh --reports-dir"  "$(_rc ./monitor/reports-roll.sh --reports-dir)"    "64"
eq "behaviour: ng --title (via _need_val, #990)" "$(_rc ./monitor/ng issue create --title)"        "64"

# PROBE PROVENANCE — WHICH LINE PRODUCED EACH rc, ESTABLISHED BY MUTATION.
# Recorded because an unstated sweep and an unrun one look identical, and
# because comparing rc TOTALS is precisely the mistake: an rc that matches for
# the wrong reason IS the bug. Each arm below was mutated to a sentinel exit
# and the probe re-run; a probe whose rc follows the sentinel demonstrably
# reaches the line it names.
#
#   guards-for-diff.sh --base       -> backstop  :175   sentinel observed  SOUND
#   ci-head-attempts.sh --repo      -> backstop  :131   sentinel observed  SOUND
#   reports-roll.sh --reports-dir   -> backstop  :70    sentinel observed  SOUND
#   ng issue create --title         -> _die_usage via _need_val (ng)        SOUND
#   retire-preflight --state-dir    -> arm       :169   sentinel observed  SOUND
#                                      (its rc 2 comes from usage() at :151,
#                                       CALLED BY that arm — the message's home
#                                       is not the producing line, which is why
#                                       text-tracing alone was not enough)
#   send.sh --file                  -> :508, NOT its arm                   DEFECT
#                                      fixed above with a window argument
#
# Six probes, one defect, five sound. Stating the all-clear explicitly: the
# five are not merely un-flagged, they were each driven under a mutated arm.
#
# AND THE COUNTEREXAMPLES, PINNED AS DATA rather than described in prose —
# prose cannot be made to fail. These are NOT endorsements of rc 1/2; they are
# the measured boundary of the claim above, and if one of them ever becomes 64
# this assertion reds and the boundary comment gets updated with it.
# THE WINDOW ARGUMENT IS LOAD-BEARING (your-org/nexus-code#1135 skeptic F18).
# `send.sh --file` — without a window — never reaches the `--file` arm at all.
# `--file` is consumed as the WINDOW positional, the parse completes, and the
# script dies far downstream at `[[ -s "$PAYLOAD" ]] || die "refusing to send
# an empty message"`. Both paths return 1, so the probe PASSED — and would have
# passed just as happily if the arm it names had been changed to 64, which is
# the single change it exists to detect.
#
# Proven by mutation rather than by reading: with the `--file` arm forced to
# `exit 64`, the old probe still returned **1**; with a window argument it
# returns **64**. It was also NON-DETERMINISTIC — with stdin open the windowed
# form is needed to avoid the script blocking on a payload read (a bare
# `send.sh --file` was observed timing out at rc 124).
#
# A probe that passes for the wrong reason and cannot fail under the mutation
# it exists to detect is this repo's dominant defect class, and it was sitting
# inside the PR about exactly that.
eq "boundary: send.sh --file is pre-empted by its own arm (NOT 64)" \
   "$(_rc ./monitor/send.sh nosuchwindow --file)" "1"
eq "boundary: retire-preflight.sh --state-dir is pre-empted (NOT 64)" "$(_rc ./monitor/retire-preflight.sh --state-dir)" "2"

# The OTHER helper, which is the one that actually diverged. `ng`'s `_need_val`
# is a separate mechanism reached from inside the arm rather than from the loop
# invariant, so the scan above cannot see it — assert its user-facing arms
# directly. Both the MISSING-value and EMPTY-value arms, because collapsing the
# split between two scripts into a split between two branches of one helper
# would be harder to see and no more correct.
eq "ng _need_val: a MISSING value is EX_USAGE" \
   "$(_rc ./monitor/ng issue create --title)" "64"
eq "ng _need_val: an EMPTY value is EX_USAGE too" \
   "$(_rc ./monitor/ng issue create --title '')" "64"

# ---- §4 the guard is load-bearing ------------------------------------------
# Prove the mechanism actually detects a stalled loop, rather than the verbs
# above happening to fail earlier for unrelated reasons.
echo '=== 4. the guard mechanism itself detects a stalled loop ==='
stall_rc=$(timeout 5 bash -c '
    _argloop_stuck() { exit 64; }
    set -- --flag
    _argloop_prev=-1; while (( $# > 0 )); do (( $# != _argloop_prev )) || _argloop_stuck "$1"; _argloop_prev=$#
        case "$1" in --flag) v="${2:-}"; shift 2 ;; *) shift ;; esac
    done' >/dev/null 2>&1; printf '%s' "$?")
eq "a stalling loop WITH the guard exits 64, not 124" "$stall_rc" "64"

# The negative control: the same loop WITHOUT the guard must actually hang, or
# §1 proves nothing about the guard.
nostall_rc=$(timeout 5 bash -c '
    set -- --flag
    while (( $# > 0 )); do
        case "$1" in --flag) v="${2:-}"; shift 2 ;; *) shift ;; esac
    done' >/dev/null 2>&1; printf '%s' "$?")
eq "…and WITHOUT the guard it hangs (124) — the defect is real" "$nostall_rc" "124"

# NESTING (your-org/nexus-code#952 skeptic F2). The guard keeps its previous
# `$#` in a variable. With ONE SHARED name, an inner guarded loop resets it and
# the outer loop then compares its own `$#` against the inner's leftover —
# measured as a FALSE POSITIVE (rc 64) on a perfectly legitimate outer loop.
# Each site therefore gets its OWN name, so nesting is always two variables.
# Not reachable in this tree today; asserted because this pattern is stamped
# into 64 sites and is the obvious thing to copy for the 65th.
# <inner-var> <outer-var> — pass the SAME name for both to stage the shared-
# global shape, or two names to stage what this PR ships.
_nest() {
    timeout 5 bash -c '
        _argloop_stuck() { exit 64; }
        inner() { '"$1"'=-1; while (( $# > 0 )); do (( $# != '"$1"' )) || _argloop_stuck "$1"; '"$1"'=$#
            shift; done; }
        outer() { '"$2"'=-1; while (( $# > 0 )); do (( $# != '"$2"' )) || _argloop_stuck "$1"; '"$2"'=$#
            inner x y; shift; done; }
        outer a b c' >/dev/null 2>&1
    printf '%s' "$?"
}
# Distinct names (what this PR ships): the outer loop completes.
eq "a nested guarded loop does NOT false-positive with per-site names" "$(_nest _argloop_prev_1 _argloop_prev_2)" "0"
# Shared name (the shape before this fix): it must still demonstrate the fault,
# or the assertion above proves nothing about the naming.
eq "…and WOULD false-positive if both sites shared one name" "$(_nest _p _p)" "64"

# ---- declared assertion count ----------------------------------------------
# ANNOUNCE, THEN COUNT (your-org/nexus-code#807): the total is captured BEFORE
# this guard records its own failure, or a mismatch overstates the run by one
# and sends the next reader hunting for an assertion that never existed.
# 29 -> 30: your-org/nexus-code#1160 adds §3's blind-spot ratchet ("no argument
# loop is INVISIBLE to the classifier"). The handler-definition assertion was
# re-keyed in place, not added, so it does not move this number.
EXPECTED=30
_total=$(( $(_th_ledger_count P) + $(_th_ledger_count F) ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
