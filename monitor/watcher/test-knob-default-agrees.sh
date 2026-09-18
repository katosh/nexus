#!/usr/bin/env bash
# Guard: a knob's numeric default is spelled in up to FIVE places, and only one
# of them is the one production reads.
#
# Run: bash monitor/watcher/test-knob-default-agrees.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Regenerate the spelling manifest:
#   bash monitor/watcher/test-knob-default-agrees.sh --emit-spellings \
#       > monitor/watcher/knob-default-spellings.manifest
#
# WHY THIS EXISTS. `_config.sh` SETS AND EXPORTS every knob at watcher startup,
# so the `${MONITOR_…:-N}` fallback in the consuming function is UNREACHABLE
# under the running watcher. It is, however, exactly the branch a unit test
# takes — suites source the consumer directly and never load `_config.sh`. The
# two defaults can therefore diverge with the suite staying green, and the
# divergence is invisible in the direction that matters: change the consumer's
# literal and the tests move while production does not.
#
# Both original instances came from the SAME change (your-org/nexus-code#966):
#
#   - `MONITOR_GRAPHQL_DEGRADED_REMIND_SECONDS` — `_github.sh` was edited first,
#     the fixture went green, and the shipped cadence had not moved. Caught by
#     hand, which is why this guard was written.
#   - `MONITOR_ALERT_EMIT_COOLDOWN_SECONDS` — the fix's OWN new knob then
#     re-instantiated the hazard, and this guard did not cover it because it was
#     written for one knob rather than for the shape. Demonstrated as a
#     surviving mutant: mutating the PRODUCTION default 900 -> 1800 produced 0
#     failures across `test-comment-surface`, this suite, and
#     `test-config-validate-guard`, while mutating the DEAD one 900 -> 0
#     produced 9. The suite was sensitive to the value production never reads
#     and blind to the one it does.
#
# ===========================================================================
# THE TABLE IS DERIVED, NOT ENUMERATED (your-org/nexus-code#995)
# ===========================================================================
#
# The guard used to hand-enumerate its knobs, two rows, with NO assertion that
# the enumeration was complete. `#995` measured the population carrying the
# hazard shape at ~67 of the knobs `_config.sh` resolves; re-derived here at
# `3458180` the resolution population is **99**. A third knob added tomorrow
# was exactly as invisible as the second one had been, and `KNOBS`' own comment
# ("Adding a knob means adding a row") is the instruction that had already been
# forgotten once. An enumeration whose completeness nothing checks is the same
# defect as a coverage boundary whose predicate nobody checks.
#
# "PASTE MORE ROWS" IS NOT THE FIX, AND THAT IS THE HARD PART. `#995` measured
# it: adding ONE legitimate row for a knob with the identical A-vs-C hazard
# turned the guard red on NON-VACUITY, not on drift —
# `MONITOR_OVER_LIMIT_MAX_ATTEMPTS` has no `_config.sh` validation fallback at
# all (spelling B absent BY DESIGN) and its docstring is whitespace-padded past
# the `E` regex. Its four real spellings all say `4` and agree. So the
# five-spelling model was specific to the two knobs it was written for.
#
# What makes it extend is treating ABSENCE as a first-class state:
#
#   * a spelling that is ABSENT is not compared. Absence is not disagreement.
#   * …but WHICH spellings are present is itself pinned, in
#     `knob-default-spellings.manifest`. So a rename or a reflow that makes an
#     extraction silently return "" turns this red NAMING the knob, instead of
#     collapsing the comparison to a smaller set that agrees. That was the
#     vacuity failure the old per-spelling assertions existed to prevent, and
#     it is the one thing "just don't require every spelling" would have
#     thrown away.
#
# So there are exactly two properties, and they are independent:
#
#   AGREEMENT  every PRESENT spelling of a knob's default is the same number.
#   PRESENCE   the set of spellings present for each knob is the recorded one.
#
# THE FIVE SPELLINGS, and which are derivable:
#
#   A  config-key default — `$("$_cfg" <key> N)` in `_config.sh`.  DERIVED.
#      THIS IS WHAT PRODUCTION RUNS. Present for every knob by construction:
#      it is what defines the population.
#   B  `_config.sh`'s own malformed-value fallback, `[[ … ]] || VAR=N`.
#      DERIVED. Legitimately absent for many knobs.
#   C  a consumer's `${VAR:-N}` — unreachable in production, taken by every
#      unit test. DERIVED corpus-wide; MORE than one distinct value across
#      consumers is itself drift and is reported as such.
#   D  the consumer function's own local-variable fallback. NOT DERIVABLE and
#      deliberately not guessed: `_emit_filters.sh` holds TWO functions whose
#      local is `cooldown` (`_filter_emit_cooldown` at 300 and
#      `_filter_alert_cooldown` at 900), so a file-scoped scan reports a false
#      disagreement. D therefore keeps a hand table naming file, function and
#      local — the one place enumeration is still correct, because the thing
#      being named cannot be discovered.
#   E  the human-readable default in a docstring. DERIVED. A comment naming a
#      stale number is how the wrong one gets "confirmed" in review.
#
# THE `E` REGEX TOLERATES PADDING, and the gain is measured. The old form
# required `VAR` + one optional character + ONE space + `(default N)`. The
# docstrings in this repo are column-aligned, arrow-annotated and backticked:
#
#     #   MONITOR_INTERVAL       -> monitor.interval_seconds      (default 60)
#     #   `MONITOR_ALERT_EMIT_COOLDOWN_SECONDS` (default 900) — per-surface …
#     #   MONITOR_CLONE_DRIFT_HOURS     hour threshold (default 24)
#
# At `3458180` the single-space form finds an `E` for **7** of the 99 knobs;
# the tolerant form finds **17**. Ten knobs' docstrings were silently outside
# the guard, which is the `#995` complaint in miniature.
#
# NON-VACUITY, AND WHY IT IS NOT PER-SPELLING ANY MORE. The old suite asserted
# each of the five extractions "extracted a number", which is the right
# instinct and the wrong level once absence is legal. The property that
# survives is: the POPULATION is not empty and is not silently shrinking (a
# floor), the PRESENCE MASK is pinned (so a spelling cannot vanish quietly),
# and the agreement comparison is DEMONSTRATED to reject a divergence — run
# against a real mutated `_config.sh`, not against a synthetic array.
#
# It asserts AGREEMENT, never a specific number. Pinning values here would add
# a SIXTH place to forget; the manifest records only WHICH spellings exist, not
# what they say.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
. "$_test_dir/_test_helpers.sh"

CONFIG_SH="$_test_dir/_config.sh"
MANIFEST="$_test_dir/knob-default-spellings.manifest"

# The population floor. Set well under the live count (99 at `3458180`) so
# ordinary growth or pruning never trips it, and present because an extractor
# broken into returning NOTHING makes every downstream comparison vacuous —
# this repo's dominant defect class, a silence read as an absence.
POP_FLOOR=60

# ---- D: the one spelling that cannot be derived ---------------------------
# <config-key>|<VAR>|<consumer-file>|<consumer-fn>|<local-var>
# `<local-var>` is named rather than discovered, for the `_emit_filters.sh`
# reason in the header. A row here is NOT a claim of coverage — every knob is
# covered by A/B/C/E whether or not it appears below. A row adds the D spelling
# for that knob, and nothing else.
KNOBS=(
  "monitor.graphql.degraded_remind_seconds|MONITOR_GRAPHQL_DEGRADED_REMIND_SECONDS|_github.sh|_graphql_note_failure|remind"
  "monitor.alert_emit_cooldown_seconds|MONITOR_ALERT_EMIT_COOLDOWN_SECONDS|_emit_filters.sh|_filter_alert_cooldown|cooldown"
)

# ---- the corpus -----------------------------------------------------------
# Every tracked shell file under monitor/ EXCEPT `_config.sh`, which supplies
# A and B and whose own `${VAR:-$(…)}` line is not a consumer fallback.
_kda_corpus_files() {
    ( cd "$REPO_ROOT" && git ls-files -- 'monitor/**/*.sh' 'monitor/*.sh' 'monitor/ng' 2>/dev/null \
        | grep -v '^monitor/watcher/_config\.sh$' )
}
# --- the `--population` protocol (your-org/nexus-code#803) -----------------
#
# WHY THIS GUARD NEEDED IT (your-org/nexus-code#1164). This suite went red on
# `dev` because `#1141` added a knob to `_config.sh` and did not regenerate the
# manifest — and NOTHING told that PR this guard existed. It declared no
# population, so it was one of the ~354 suites INVISIBLE to
# `guards-for-diff`: not in `SELECTED`, not in `CONSIDERED AND EXCLUDED`, and
# therefore indistinguishable from a guard that was considered and ruled out.
# `guards-for-diff --run` on that diff exits 0 and names this file nowhere,
# which is `#1078`'s complaint reproduced against the one guard whose whole
# subject is a value that goes silently unreachable.
#
# The population is the guard's OWN enumerator plus the three files it reads
# that the enumerator deliberately excludes or predates: `_config.sh` (the
# corpus function filters it out, because it supplies A and B rather than C),
# the manifest, and the sourced libraries. Calling `_kda_corpus_files` rather
# than restating what it currently returns is the protocol's one rule — a
# hand-copied list is a second implementation of the population, and it drifts.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    _kda_corpus_files
    printf '%s\n' "$CONFIG_SH" "$MANIFEST" \
        "$_test_dir/_test_helpers.sh" "$_test_dir/../_guard_population.sh"
}
gp_handle "$@"

# ---- A and B, from a given _config.sh -------------------------------------
# Parameterised on the FILE so the potency control below can run the REAL
# extractor over a MUTATED copy. A control that exercises a synthetic array
# proves nothing about the extractor that guards the tree.
#
# Emits `key<TAB>lhs<TAB>var<TAB>A<TAB>B` per knob.
_kda_ab() {   # <config.sh>
    local cfg="$1"
    LC_ALL=C awk '
    /^[A-Za-z_][A-Za-z0-9_]*="\$\{[A-Za-z_][A-Za-z0-9_]*:-\$\("\$_cfg" [a-zA-Z0-9_.]+ [0-9]+\)\}"$/ {
        line = $0
        eq = index(line, "=")
        lhs = substr(line, 1, eq - 1)
        s = line; sub(/^[^{]*\{/, "", s); var = s; sub(/:-.*$/, "", var)
        s = line; sub(/^.*"\$_cfg" /, "", s); key = s; sub(/ .*$/, "", key)
        s = line; sub(/^.*"\$_cfg" [a-zA-Z0-9_.]+ /, "", s); a = s; sub(/\).*$/, "", a)
        pop[lhs] = key "\t" lhs "\t" var "\t" a
        order[++n] = lhs
        next
    }
    # B — the malformed-value fallback: `NAME=<digits>` NOT at line start,
    # or on its own inside an if. `==` is a comparison, never a default.
    {
        if ($0 ~ /==/) next
        s = $0
        while (match(s, /(^|[|;( \t])[A-Za-z_][A-Za-z0-9_]*=[0-9]+([ \t)]|$)/)) {
            tok = substr(s, RSTART, RLENGTH)
            gsub(/^[|;( \t]|[ \t)]$/, "", tok)
            nm = tok; sub(/=.*$/, "", nm)
            vl = tok; sub(/^.*=/, "", vl)
            if (!(nm in bfall)) bfall[nm] = vl
            s = substr(s, RSTART + RLENGTH)
        }
    }
    END {
        for (i = 1; i <= n; i++) {
            lhs = order[i]
            printf "%s\t%s\n", pop[lhs], (lhs in bfall ? bfall[lhs] : "")
        }
    }' "$cfg"
}

# ---- C and E, from the corpus --------------------------------------------
# `C` is unambiguous: `VAR:-<digits>`. `E` is attributed to the LAST knob name
# appearing before `(default N)` on the line — the docstrings put the config
# key and prose in between, so "the identifier immediately before" is wrong and
# an unbounded backward scan is quadratic on long lines. Restricting the scan
# to names already in the population makes it both correct and cheap: the whole
# extraction runs in ~0.2s over 520 files.
_kda_ce() {   # <population-var-list-file> ; emits `C|E<TAB>VAR<TAB>value`
    local popf="$1"
    # `while IFS= read -r` and not `mapfile`: this workspace is zsh-default,
    # `mapfile` does not exist there, and its failure mode is an EMPTY ARRAY at
    # rc 127 rather than an error anyone notices — an enumeration that returns
    # zero and reads as "the population is empty". `run-tests.sh` honours
    # `NEXUS_TEST_SHELL`, so the interpreter is not this file's to assume.
    local -a files=(); local _f
    while IFS= read -r _f; do [[ -n "$_f" ]] && files+=("$_f"); done < <( _kda_corpus_files )
    (( ${#files[@]} )) || return 1
    ( cd "$REPO_ROOT" || return 1
      LC_ALL=C grep -hoE '[A-Za-z_][A-Za-z0-9_]*:-[0-9]+' "${files[@]}" 2>/dev/null \
        | LC_ALL=C sed -E 's/:-/\tC\t/' | LC_ALL=C awk -F'\t' '{print "C\t" $1 "\t" $3}'
      LC_ALL=C grep -hE '\(default[[:space:]]+[0-9]+\)' "${files[@]}" 2>/dev/null \
        | LC_ALL=C awk -v popf="$popf" '
            BEGIN { while ((getline v < popf) > 0) pop[v] = 1 }
            {
                i = index($0, "(default"); if (i == 0) next
                before = substr($0, 1, i - 1)
                val = substr($0, i); sub(/^\(default[ \t]+/, "", val); sub(/\).*$/, "", val)
                if (val !~ /^[0-9]+$/) next
                last = ""; t = before
                while (match(t, /[A-Za-z_][A-Za-z0-9_]*/)) {
                    tok = substr(t, RSTART, RLENGTH)
                    if (tok in pop) last = tok
                    t = substr(t, RSTART + RLENGTH)
                }
                if (last != "") printf "E\t%s\t%s\n", last, val
            }'
    ) | LC_ALL=C sort -u
}

# ---- D, for the hand-table knobs only -------------------------------------
_fn_body() {  # <file> <fn>
    awk -v fn="$2" '$0 ~ "^"fn"\\(\\) \\{" {c=1} c {print} c && /^\}/ {exit}' "$1"
}
_kda_d() {    # emits `D<TAB>VAR<TAB>value`
    local row key var cfile cfn clocal body _re
    for row in "${KNOBS[@]}"; do
        IFS='|' read -r key var cfile cfn clocal <<<"$row"
        [[ -r "$_test_dir/$cfile" ]] || continue
        body=$(_fn_body "$_test_dir/$cfile" "$cfn")
        _re='(^|[|;[:space:]])'"$clocal"'=([0-9]+)([[:space:]]|$)'
        while IFS= read -r ln; do
            [[ "$ln" == *'=='* ]] && continue
            [[ "$ln" =~ $_re ]] && { printf 'D\t%s\t%s\n' "$var" "${BASH_REMATCH[2]}"; break; }
        done <<<"$body"
    done
}

# ---- combine --------------------------------------------------------------
# Emits `VAR<TAB>MASK<TAB>A<TAB>B<TAB>C<TAB>D<TAB>E` where MASK is the four
# characters ABCE (D is not in the mask: it exists only where a hand row does,
# so pinning it would pin the hand table rather than the tree).
#
# NOT `IFS=$'\t' read`. Tab is an IFS WHITESPACE character in bash, so runs of
# tabs collapse and EMPTY fields vanish — which silently shifts every column
# after the first absent spelling. That mis-shift produced "93 of 99 divergent"
# while writing this file, on a tree whose real answer is 0. awk with an
# explicit `FS` does not collapse; `|` as a separator does not either.
_kda_table() {   # <config.sh>
    local cfg="$1" popf ab ce d
    ab=$(_kda_ab "$cfg") || return 1
    popf=$(mktemp) || return 1
    printf '%s\n' "$ab" | cut -f3 | LC_ALL=C sort -u > "$popf"
    ce=$(_kda_ce "$popf") || { rm -f "$popf"; return 1; }
    rm -f "$popf"
    d=$(_kda_d)
    # `$ce`$'\n'`$d`, NOT `"$ce$d"`. Command substitution strips the trailing
    # newline, so plain concatenation GLUES the last C/E row onto the first D
    # row — measured while writing this: `E<TAB>MONITOR_SCHEDULER_MAX_SLEEP<TAB>10`
    # ran into `D<TAB>…`, producing the value `10D`, which then read as a
    # divergence on a knob whose two spellings both say 10.
    printf '%s\n' "$ab" | LC_ALL=C awk -F'\t' -v ced="$ce"$'\n'"$d" '
        BEGIN {
            nl = split(ced, rows, "\n")
            for (i = 1; i <= nl; i++) {
                if (rows[i] == "") continue
                split(rows[i], f, "\t")
                k = f[1] SUBSEP f[2]
                if (!(k in seen)) { seen[k] = f[3] } else if (index("," seen[k] ",", "," f[3] ",") == 0) { seen[k] = seen[k] "," f[3] }
            }
        }
        {
            key = $1; lhs = $2; var = $3; a = $4; b = $5
            c = (("C" SUBSEP var) in seen) ? seen["C" SUBSEP var] : ""
            e = (("E" SUBSEP var) in seen) ? seen["E" SUBSEP var] : ""
            dd = (("D" SUBSEP var) in seen) ? seen["D" SUBSEP var] : ""
            mask = (a != "" ? "A" : "-") (b != "" ? "B" : "-") (c != "" ? "C" : "-") (e != "" ? "E" : "-")
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", var, mask, a, b, c, dd, e
        }' | LC_ALL=C sort -u
}

# Divergent knobs: those whose PRESENT spellings do not all name one number.
_kda_divergent() {   # reads a table on stdin
    LC_ALL=C awk -F'\t' '
    {
        var = $1; mask = $2
        n = split($3 "," $4 "," $5 "," $6 "," $7, parts, ",")
        delete seen; u = 0
        for (i = 1; i <= n; i++) if (parts[i] != "" && !(parts[i] in seen)) { seen[parts[i]] = 1; u++ }
        if (u > 1) printf "%s\tmask=%s\tA=%s B=%s C=%s D=%s E=%s\n", var, mask, $3, $4, $5, $6, $7
    }'
}

TABLE=$(_kda_table "$CONFIG_SH")

if [[ "${1:-}" == "--emit-spellings" ]]; then
    printf '%s\n' "$TABLE" | LC_ALL=C awk -F'\t' 'NF { printf "%s\t%s\n", $1, $2 }' | LC_ALL=C sort -u
    exit 0
fi

N_POP=$(printf '%s\n' "$TABLE" | grep -c . )

# --- 1. the population is real ---------------------------------------------
assert_eq "population: _config.sh resolves at least $POP_FLOOR numeric-default knobs (got $N_POP)" \
    "$( (( N_POP >= POP_FLOOR )) && echo yes || echo no )" "yes"

# --- 2. COMPLETENESS: no numeric-default knob escapes the parser ------------
# The `#995` complaint was a hand list with nothing checking it. A DERIVED list
# has the same failure one level down: a knob written in a spelling the row
# regex does not recognise drops out silently and looks exactly like a knob
# that is not there. So count the shape independently — every `$("$_cfg" <key>
# <numeric>)` occurrence — and require the parser to claim all of them.
_cfg_numeric_calls=$(LC_ALL=C grep -oE '\$\("\$_cfg" [a-zA-Z0-9_.]+ [0-9]+\)' "$CONFIG_SH" | LC_ALL=C sort -u | grep -c . )
assert_eq "completeness: every \$_cfg call with a numeric literal default is a row ($_cfg_numeric_calls calls)" \
    "$N_POP" "$_cfg_numeric_calls"

# --- 3. AGREEMENT ----------------------------------------------------------
_div=$(printf '%s\n' "$TABLE" | _kda_divergent)
if [[ -z "$_div" ]]; then
    echo "  PASS: every PRESENT spelling of every knob's default agrees ($N_POP knobs)"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: a knob's default is spelled two different ways:" >&2
    printf '%s\n' "$_div" | sed 's/^/        /' >&2
    echo "        A is what production runs. C is what every unit test takes." >&2
    echo "        If they disagree, one of them is silently inert." >&2
    FAIL=$(( FAIL + 1 ))
fi

# --- 4. POTENCY for (3), on a REAL mutated tree ----------------------------
# The comparison must be shown to REJECT a divergence, or "0 divergent" is a
# zero from an instrument nobody has seen fire. Driven by mutating a COPY of
# `_config.sh` and running the SAME extractor over it — not by comparing a
# synthetic array, which would exercise a copy of the comparison rather than
# the extractor that guards the tree.
_kda_mut=$(mktemp) || { echo "mktemp failed" >&2; exit 1; }
_kda_victim=$(printf '%s\n' "$TABLE" | LC_ALL=C awk -F'\t' '$2 ~ /^A.C/ { print $1; exit }')
if [[ -n "$_kda_victim" ]]; then
    # Anchored on `{VAR:-$("$_cfg" <key> N)`, NOT on `^VAR=`. The ASSIGNED name
    # and the ENVIRONMENT-VARIABLE name differ for many knobs
    # (`RETENTION_DAYS="${DIFF_RETENTION_DAYS:-…}"`), so a `^VAR=` anchor
    # mutates nothing for those — and a mutation control that mutates nothing
    # passes for the wrong reason, which is the one failure it exists to rule
    # out. It did exactly that while this file was being written; requiring the
    # victim to be NAMED in the result is what caught it.
    # Built SINGLE-QUOTED and concatenated, never as one double-quoted string.
    # `"…\\$_cfg…"` in double quotes hands sed a pattern in which the shell has
    # already EXPANDED `$_cfg` — an unset variable, so the pattern silently
    # became `\$\("\" …` and matched nothing. Measured: the mutation control
    # then found no divergence and the guard failed for a reason that had
    # nothing to do with the tree.
    _kda_prog='s/('"${_kda_victim}"':-.*"\$_cfg" [a-zA-Z0-9_.]+ )[0-9]+\)/\1999777)/'
    LC_ALL=C sed -E "$_kda_prog" "$CONFIG_SH" > "$_kda_mut"
    _mut_div=$(_kda_table "$_kda_mut" | _kda_divergent)
    assert_contains "control: a PRODUCTION-side drift is REJECTED, by the real extractor on a real mutated _config.sh" \
        "$_mut_div" "$_kda_victim"
    assert_eq "control: …and the mutation is the ONLY divergence it manufactures" \
        "$(printf '%s\n' "$_mut_div" | grep -c . )" "1"
else
    echo "  FAIL: no knob carries both an A and a C spelling — the mutation control cannot be built" >&2
    FAIL=$(( FAIL + 1 ))
fi
rm -f "$_kda_mut"

# --- 5. PRESENCE: the spelling mask is pinned ------------------------------
# This is what makes absence first-class WITHOUT making it free. A spelling may
# be legitimately absent; it may not silently BECOME absent, because that turns
# the agreement check above into a comparison over a smaller set that agrees.
_live_mask=$(printf '%s\n' "$TABLE" | LC_ALL=C awk -F'\t' 'NF { printf "%s\t%s\n", $1, $2 }' | LC_ALL=C sort -u)
if [[ -r "$MANIFEST" ]]; then
    _rec_mask=$(grep -v '^#' "$MANIFEST" | grep . | LC_ALL=C sort -u)
    if [[ "$_live_mask" == "$_rec_mask" ]]; then
        echo "  PASS: the per-knob spelling mask matches the manifest ($(printf '%s\n' "$_rec_mask" | grep -c . ) knobs)"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: the set of spellings present per knob has CHANGED." >&2
        echo "        REGENERATING IS NOT A FIX. Decide which happened:" >&2
        echo "          + a knob GAINED a spelling — check it agrees, then regenerate." >&2
        echo "          - a knob LOST one — is that a deliberate deletion, or did a" >&2
        echo "            rename/reflow make an extraction silently return \"\"? The" >&2
        echo "            second is the vacuity failure this manifest exists to catch:" >&2
        echo "            the agreement check would then pass over a smaller set." >&2
        echo "          * a knob APPEARED or VANISHED — assertion 2 should have caught" >&2
        echo "            a parser miss; if it did not, the row shape changed." >&2
        echo "        Regenerate with:" >&2
        echo "          bash monitor/watcher/test-knob-default-agrees.sh --emit-spellings \\" >&2
        echo "              > monitor/watcher/knob-default-spellings.manifest" >&2
        diff <(printf '%s\n' "$_rec_mask") <(printf '%s\n' "$_live_mask") | sed 's/^/        /' >&2 || true
        FAIL=$(( FAIL + 1 ))
    fi
    # POTENCY for the ratchet, varying the axis the MECHANISM varies on — the
    # MANIFEST, with the corpus held constant. Mutating the corpus instead
    # would test the extractor, which assertion 4 already does.
    _bogus=$(printf '%s\n%s\n' "$_rec_mask" "ZZ_KNOB_THAT_DOES_NOT_EXIST	A---" | LC_ALL=C sort -u)
    assert_eq "control: the mask ratchet REJECTS a manifest with one extra row" \
        "$( [[ "$_live_mask" != "$_bogus" ]] && echo rejected || echo accepted )" "rejected"
    _short=$(printf '%s\n' "$_rec_mask" | tail -n +2)
    assert_eq "control: …and one with a row REMOVED" \
        "$( [[ "$_live_mask" != "$_short" ]] && echo rejected || echo accepted )" "rejected"
else
    echo "  FAIL: missing $MANIFEST — the presence of each spelling would go unchecked" >&2
    FAIL=$(( FAIL + 1 ))
fi

# --- 6. the hand table still resolves --------------------------------------
# D is the one spelling that cannot be derived, so its rows are the one place a
# stale name hides. A row naming a function that no longer exists yields no D
# value, and D would then simply drop out of the agreement check — absence
# reading as agreement, which is the failure this whole file is about.
for row in "${KNOBS[@]}"; do
    IFS='|' read -r _k _var _cf _cfn _cl <<<"$row"
    assert_eq "$_var [D fn-validate] still resolves in $_cf:$_cfn" \
        "$(_kda_d | LC_ALL=C awk -F'\t' -v v="$_var" '$2==v {print "yes"; exit}')" "yes"
done

# --- 7. the E regex tolerates the padding these docstrings actually use -----
# Pinned as a FLOOR rather than an exact count so ordinary docstring edits do
# not churn it, and present because the whitespace fix is the difference
# between 7 knobs covered and 17 (measured at `3458180`). A regression to the
# single-space form collapses this.
_e_count=$(printf '%s\n' "$TABLE" | LC_ALL=C awk -F'\t' '$7 != "" {n++} END {print n+0}')
assert_eq "the E extraction reaches padded/arrowed docstrings (>=10 knobs; single-space form reached 7)" \
    "$( (( _e_count >= 10 )) && echo yes || echo no )" "yes"

# ---- assertion-count guard ----------------------------------------------
# `test-summary-honesty-manifest.sh` requires a ledger-carrying suite to pin
# its assertion total. Rightly: this file's subject is a value that is silently
# unreachable, so a version of it that quietly ran a subset would be the same
# defect wearing its name.
#   1 population + 1 completeness + 1 agreement + 2 drift controls
# + 1 mask + 2 mask controls + 1 E floor + 1 per hand row
EXPECTED_ASSERTIONS=$(( 9 + ${#KNOBS[@]} ))
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
