#!/usr/bin/env bash
# gate-coverage.sh — the cc-harness gate's POPULATION rules, in one place.
#
# Sourced by monitor/cc-harness/gate.sh. Two jobs, both of which exist
# because a gate that reports GREEN over a population it never established
# is reporting about nothing:
#
#   1. `gate_refuse_if_vacuous` — THE VACUOUS-POPULATION RULE
#      (your-org/nexus-code#1268). A population of size zero is a REFUSAL,
#      never a clearance. The filed instance was the scenario list: with
#      zero scenarios the gate printed `0 passed / 0 failed / 0 skipped
#      (of 0)` and `GATE GREEN (0/0 passed) — candidate is safe to
#      promote`, exit 0. That is the SAME failure the gate was written
#      against — its own header cites a prior gate that "printed GREEN with
#      every scenario skipped for lack of node" — closed for `skipped` and
#      left open for `empty`.
#
#      It is a FUNCTION and not an inline check on purpose. The defect is a
#      CLASS, not a line: this file computes three populations (executed
#      scenarios, pane-state vocabulary, delivery transports) and every one
#      of them renders as "nothing to complain about" when it comes back
#      empty. One rule, applied at every site, is the only shape that
#      cannot grow a fourth unguarded site quietly.
#
#      A count that is not a NUMBER is refused too, and for the same reason
#      the gate already refuses `lint=unknown`: "I could not count this
#      population" is not "this population is fine". An emptiness check is a
#      presence test wearing a validity test's name — so the shape is
#      validated, not just the emptiness.
#
#   2. `gcov_report` — THE COVERAGE BOUNDARY (your-org/nexus-code#1261).
#      `GATE GREEN (7/7)` is a tally over a HARDCODED list, and it drives an
#      automatic version bump of the binary every agent on the board runs.
#      7/7 reads as completeness; measured on this tree it is 7 of 12
#      pane-state states and 0 of 2 delivery transports. The ratio was the
#      only number in the artefact, and it said nothing about its own
#      denominator.
#
#      DERIVED, NOT HAND-ENUMERATED. The pane-state vocabulary comes from
#      `monitor/pane-state.sh --states` — the tool IS the vocabulary; CLAUDE.md
#      records that a hand-copied list omitted `unknown` and that the omission
#      was the dangerous one. The delivery-transport vocabulary comes from
#      running each `monitor/harness/*.sh transports` adapter, which is where
#      `monitor/send.sh` itself gets it.
#
#      DECLARED, for the per-scenario half. What a scenario COVERS cannot be
#      derived soundly from its text: a grep over-claims on a state named in a
#      comment and under-claims on one reached through a variable, and
#      over-claiming is the direction that matters in a coverage report. So
#      coverage is DECLARED in gate-coverage.tsv and the derivation is used as
#      a FALSIFIER: a declared member whose token does not appear in the
#      scenario file at all is refused. That check is necessary and not
#      sufficient, and it errs PERMISSIVE — say so rather than calling it
#      verification.
#
#      THE RATCHET. Every `test-realmodel-*.sh` on disk must be either GATED
#      or EXEMPT-with-a-reason. A scenario file that exists and is in neither
#      set is a REFUSAL. gate.sh's own comment already names this hazard —
#      "adding the file without adding this line would have reproduced #724
#      one level down" — and until now nothing enforced it. Measured at
#      5bd6d400 there were two such files.
#
#      GAPS ARE REPORTED, NOT RED. An uncovered pane-state is a fact about the
#      suite, not a defect in the candidate; making it red would pin the gate
#      permanently red and teach every reader to ignore it. What changes is
#      that the GREEN line now carries its boundary, so neither an operator
#      nor an automated bump can read 7/7 as "everything".
#
# Return codes (functions):
#   0  ok
#   3  REFUSED — the population could not be established, or a declaration
#      contradicts the derived vocabulary. gate.sh turns this into exit 2.
#
# Test injection points (mirroring `_GATE_GIT_BIN` in gate.sh, which is the
# established idiom here for driving an unavailable-tool arm without a
# fixture tree):
#   GCOV_PANE_STATE_BIN   path to the pane-state tool
#   GCOV_HARNESS_DIR      directory of delivery adapters
#   GCOV_MANIFEST         path to the coverage manifest
#   GCOV_SCENARIO_DIR     directory scanned for on-disk realmodel scenarios

_gcov_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_gcov_repo=$(cd "$_gcov_self_dir/../.." && pwd)

# ---- 1. the vacuous-population rule (your-org/nexus-code#1268) ------------
#
# gate_refuse_if_vacuous <label> <count> [<detail>]
#   rc 0  the population has at least one member
#   rc 3  REFUSED — zero members, or a count that is not a number
gate_refuse_if_vacuous() {
    local label="$1" n="${2-}" detail="${3:-}"
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
        echo "=== gate-population: REFUSED label=${label} count=NOT-ESTABLISHED ==="
        echo "gate.sh: REFUSED — the size of the '${label}' population could not be established (count='${n}')." >&2
        echo "gate.sh: 'I could not count it' is not 'it is fine'. ${detail}" >&2
        return 3
    fi
    if (( n == 0 )); then
        echo "=== gate-population: REFUSED label=${label} count=0 ==="
        echo "gate.sh: REFUSED — the '${label}' population is EMPTY, so nothing was measured." >&2
        echo "gate.sh: a gate's empty case is a refusal, never a clearance: rendering 'nothing ran'" >&2
        echo "gate.sh: as 'safe to promote' is your-org/nexus-code#1268. ${detail}" >&2
        return 3
    fi
    return 0
}

# ---- 2a. derived vocabularies --------------------------------------------

# gcov_pane_state_vocabulary — one state per line, on stdout.
# The TOOL is the vocabulary. Never hand-enumerate this list.
gcov_pane_state_vocabulary() {
    local tool="${GCOV_PANE_STATE_BIN:-$_gcov_repo/monitor/pane-state.sh}"
    local out rc
    if [[ ! -r "$tool" ]]; then
        echo "gcov: no readable pane-state tool at $tool" >&2
        return 3
    fi
    out=$(bash "$tool" --states 2>/dev/null); rc=$?
    if (( rc != 0 )); then
        echo "gcov: '$tool --states' failed (rc=$rc) — the pane-state vocabulary is NOT established" >&2
        return 3
    fi
    printf '%s\n' "$out" | sed -e 's/[[:space:]]*$//' -e '/^$/d' | sort -u
}

# gcov_refuse_if_untracked <label> <repo> <file>… — rc 0 when every file is
# TRACKED (or trackedness cannot be decided at all, which is stated); rc 3
# REFUSED when any is untracked.
#
# WHY THIS EXISTS (your-org/nexus-code#1320, skeptic Q1). The two population
# scans below are FILESYSTEM globs, not `git ls-files`. That is deliberate and
# correct for what they do -- a scenario that exists on disk but is not
# declared must be SEEN, which is the whole point of the ratchet. But it means
# an UNTRACKED file can SATISFY a requirement rather than violate it, and both
# requirements below are REFUSALS:
#
#   - the delivery-transport vocabulary feeds `undeclared_transport`; an
#     untracked adapter declaring the missing transport SATISFIES it.
#   - `gate_refuse_if_vacuous "on-disk realmodel scenarios"` takes a vacuous
#     population to non-vacuous with ONE untracked file.
#
# MEASURED: empty scenario dir -> count=0 rc=3 REFUSED; plant one untracked
# `test-realmodel-*.sh` -> count=1 rc=0 CLEARED.
#
# Until #1320 the whole-tree `dirty=` predicate blocked a bump on ANY untracked
# file, so this was blocked incidentally -- indiscriminately, and only because
# the bump path was unreachable at all. #1320 makes that path reachable, so the
# incidental block is gone and this needs its OWN guard, aimed at the property:
# a population member that HEAD does not identify.
#
# FAIL-CLOSED, and "could not ask git" is stated rather than treated as clean.
gcov_refuse_if_untracked() {
    local label="$1" repo="$2"; shift 2
    local f rel untracked=0 undecidable=0 outside=0
    for f in "$@"; do
        # OUT-OF-REPO POPULATIONS ARE NOT A TRACKEDNESS QUESTION. `GCOV_HARNESS_DIR`
        # and `GCOV_SCENARIO_DIR` point the scans at fixture trees under /tmp for
        # this file's own tests, exactly as `CCH_GATE_SCENARIOS` does for gate.sh.
        # Asking `git ls-files` about a path that is not in the repo returns
        # "not tracked" TRUTHFULLY and means something else entirely -- it would
        # refuse every fixture run. Same doctrine as gate.sh's override note: the
        # override changes what is SCANNED; it does not make the scanned thing a
        # member of this repository. Skipped and COUNTED, never silently passed.
        case "$f" in
            "$repo"/*) : ;;
            *) outside=$(( outside + 1 )); continue ;;
        esac
        rel="${f#${repo}/}"
        if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            undecidable=1; break
        fi
        if ! git -C "$repo" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
            echo "=== gate-coverage: REFUSED reason=untracked_population_member label=${label} member=${rel} ===" 
            echo "gcov: REFUSED — '${rel}' is in the '${label}' population but is NOT TRACKED." >&2
            echo "gcov: an untracked member SATISFIES this population's requirement without" >&2
            echo "gcov: being identified by HEAD, so the gate would clear on evidence the" >&2
            echo "gcov: recorded sha does not describe (your-org/nexus-code#1320)." >&2
            untracked=1
        fi
    done
    if (( undecidable )); then
        # FAIL-CLOSED, as the header above promises and this arm did not
        # deliver until your-org/nexus-code#1412's suite drove it: "could not
        # ask git" returned 0 with a NOTE, i.e. it was treated as clean. The
        # repo this is asked about is the nexus checkout itself (fixture trees
        # are reached through the override dirs and are SKIPPED above as
        # outside members), so a repo that is not a work tree is a broken
        # invocation, never a legitimate clean answer.
        echo "=== gate-coverage: REFUSED reason=trackedness_undecidable label=${label} repo=${repo} ==="
        echo "gcov: REFUSED — trackedness of the '${label}' population could not be decided (${repo} is not a \`git\` work tree); a guard that could not run is not a guard that passed." >&2
        return 3
    fi
    if (( outside )); then
        echo "gcov: NOTE — ${outside} member(s) of the '${label}' population lie outside ${repo} (an override-pointed fixture tree); trackedness was NOT asked of them." >&2
    fi
    (( untracked == 0 )) || return 3
    return 0
}

# gcov_delivery_vocabulary — one transport name per line, on stdout.
# Asked of the adapters, which is where monitor/send.sh gets it
# (`"$ADAPTER" transports "$WINDOW"`, send.sh:319).
gcov_delivery_vocabulary() {
    local hdir="${GCOV_HARNESS_DIR:-$_gcov_repo/monitor/harness}"
    local a out rc any=0 acc=""
    local -a _gcov_adapters=()
    if [[ ! -d "$hdir" ]]; then
        echo "gcov: no delivery-adapter directory at $hdir" >&2
        return 3
    fi
    for a in "$hdir"/*.sh; do
        # Guards the unmatched-glob case in BOTH shell modes: under nullglob
        # the loop simply does not run, without it the literal pattern fails
        # -r here. Either way the accumulator stays empty and the caller's
        # vacuity check refuses — no bare-form fallthrough (CLAUDE.md).
        [[ -r "$a" ]] || continue
        out=$(NEXUS_ROOT="$_gcov_repo" bash "$a" transports "__cc_gate_coverage_probe__" 2>/dev/null); rc=$?
        if (( rc != 0 )); then
            echo "gcov: delivery adapter '$a' failed its transports probe (rc=$rc) — the transport vocabulary is NOT established" >&2
            return 3
        fi
        any=1
        _gcov_adapters+=( "$a" )
        acc+="$out"$'\n'
    done
    if (( any == 0 )); then
        echo "gcov: no readable delivery adapter under $hdir" >&2
        return 3
    fi
    # #1320: an UNTRACKED adapter can satisfy `undeclared_transport`.
    gcov_refuse_if_untracked "delivery adapters" "$_gcov_repo" "${_gcov_adapters[@]}" || return 3
    printf '%s' "$acc" | cut -f1 | sed -e 's/[[:space:]]*$//' -e '/^$/d' | sort -u
}

# ---- 2b. the declaration --------------------------------------------------

# gcov_manifest_path — where the declaration lives.
gcov_manifest_path() { printf '%s' "${GCOV_MANIFEST:-$_gcov_self_dir/gate-coverage.tsv}"; }

# _gcov_rows <kind> — emit the manifest's rows of one kind, comments and
# blank lines stripped, as raw TSV.
_gcov_rows() {
    local kind="$1" mf line
    mf=$(gcov_manifest_path)
    [[ -r "$mf" ]] || return 3
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line// /}" ]] && continue
        case "$line" in \#*) continue;; esac
        case "$line" in "$kind"$'\t'*) printf '%s\n' "$line";; esac
    done < "$mf"
    return 0
}

_gcov_field() { printf '%s' "$1" | cut -f"$2"; }

# _gcov_reason_owned <reason> — does this exemption have somewhere to be
# re-argued? Deliberately the SAME predicate as
# test-guard-positive-controls.sh:_none_owned (your-org/nexus-code#1482), so
# the two files that carry exemptions carry ONE rule rather than two that
# drift. A tracker ref or a dated expiry; prose alone is not ownership.
_gcov_reason_owned() {
    [[ "$1" == *\#[0-9]* || "$1" == *until:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]* ]]
}

# _gcov_split_csv <csv> — one member per line; the literal '-' means none.
# NOTE the `printf '%s\n'`, not `printf '%s'`. Without the trailing newline the
# final field arrives at `read` with no line terminator, so `read` sets the
# variable AND returns non-zero — and a plain `while read` loop drops the LAST
# member of every list silently. Measured here before the fix: 3 states counted
# as covered where 7 are declared, reported as a plausible coverage ratio with
# nothing on stderr. The `|| [[ -n "$m" ]]` at every consuming loop is the
# second belt.
_gcov_split_csv() {
    local v="$1"
    [[ -z "$v" || "$v" == "-" ]] && return 0
    printf '%s\n' "$v" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
}

# _gcov_has <needle> [<member>...] — membership by LITERAL EQUALITY, with no
# pipeline. Two reasons it is not `printf ... | grep -qxF`: `grep -q` exits on
# the first match, so under `set -o pipefail` the producer can take SIGPIPE and
# the pipeline reports 141 — a membership test that fails for a reason having
# nothing to do with membership. And an equality arm cannot be shadowed by a
# pattern, which is the property CLAUDE.md asks of any classifier.
_gcov_has() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# ---- 2c. the report -------------------------------------------------------
#
# gcov_report <production-scenario-path>...
#   Prints the coverage block. rc 0 = boundary established (gaps may exist
#   and are reported); rc 3 = REFUSED.
#
# NOTE THE SUBJECT: this is computed over the PRODUCTION scenario list, never
# over an overridden one. gate.sh's CCH_GATE_SCENARIOS knob exists for its own
# classification test, and if the coverage rules were computed over whatever
# that knob supplied, setting it would be a way to make the boundary checks
# disappear — the gate's success path reachable without the work happening.
gcov_report() {
    local -a prod=( "$@" )
    local vocab_pane vocab_deliv mf
    local -a v_pane=() v_deliv=()
    local s b m line st tr n refused=0

    mf=$(gcov_manifest_path)
    if [[ ! -r "$mf" ]]; then
        echo "=== gate-coverage: REFUSED reason=no_manifest path=$mf ==="
        echo "gate.sh: REFUSED — the coverage declaration is unreadable at $mf, so the gate cannot state what it covers (your-org/nexus-code#1261)." >&2
        return 3
    fi

    vocab_pane=$(gcov_pane_state_vocabulary) || {
        echo "=== gate-coverage: REFUSED reason=pane_state_vocabulary_unavailable ==="
        return 3
    }
    vocab_deliv=$(gcov_delivery_vocabulary) || {
        echo "=== gate-coverage: REFUSED reason=delivery_vocabulary_unavailable ==="
        return 3
    }

    while IFS= read -r line || [[ -n "$line" ]]; do [[ -n "$line" ]] && v_pane+=( "$line" ); done <<< "$vocab_pane"
    while IFS= read -r line || [[ -n "$line" ]]; do [[ -n "$line" ]] && v_deliv+=( "$line" ); done <<< "$vocab_deliv"

    # THE SAME VACUITY RULE, at the two derived populations. A vocabulary that
    # came back empty would make every "N/N covered" line read as full
    # coverage of nothing — #1268's shape, one axis over.
    gate_refuse_if_vacuous "pane-state vocabulary" "${#v_pane[@]}" \
        "monitor/pane-state.sh --states returned no states." || {
        echo "=== gate-coverage: REFUSED reason=pane_state_vocabulary_empty ==="; return 3; }
    gate_refuse_if_vacuous "delivery-transport vocabulary" "${#v_deliv[@]}" \
        "no monitor/harness adapter declared a transport." || {
        echo "=== gate-coverage: REFUSED reason=delivery_vocabulary_empty ==="; return 3; }

    # ---- declarations ----
    local -a gated_names=() exempt_names=()
    local -a cov_pane=() cov_deliv=()
    local rows

    rows=$(_gcov_rows exempt) || { echo "=== gate-coverage: REFUSED reason=manifest_unreadable ==="; return 3; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        b=$(_gcov_field "$line" 2)
        n=$(_gcov_field "$line" 5)
        if [[ -z "${n// /}" ]]; then
            echo "=== gate-coverage: REFUSED reason=exempt_without_reason scenario=$b ==="
            echo "gate.sh: REFUSED — '$b' is declared EXEMPT with no reason. An exemption nobody had to justify is an omission with a row in front of it." >&2
            refused=1
        elif ! _gcov_reason_owned "$n"; then
            # AN EXEMPTION MUST BE RE-JUSTIFIED, NOT INHERITED
            # (your-org/nexus-code#1486, extending #1482's rule for a `none`
            # positive-control row to the file with the same shape).
            #
            # A REASON IS NOT AN OWNER. This gate already required prose, and
            # prose is what it got: one row's note said, in its own words, that
            # NO RATIONALE IS ON RECORD for the exemption — a sentence that
            # satisfies "has a reason" while conceding there is none. That is
            # the #1469 shape exactly, and #1469's exemption turned out to be
            # UNNECESSARY as well as unowned, which is what makes an unowned
            # exemption worth chasing rather than shrugging at.
            #
            # So the same predicate #1482 applies to a `none` row applies here:
            # a tracker ref (`#NNNN` / `owner/repo#NNNN`) or an
            # `until:YYYY-MM-DD` date. Either one gives the exemption somewhere
            # to be re-argued; prose alone gives it somewhere to be inherited.
            #
            # WHY IT MATTERS MORE THAN TWO ROWS: this gate is what certifies a
            # Claude Code release safe to promote, and it declares its own
            # boundary honestly — a GREEN is a claim about the COVERED members
            # only. Two of ten scenarios sit outside it, `tmux-paste` is 0/2 on
            # the delivery axis, and that is the transport the watcher uses to
            # reach the orchestrator: the path whose failure archived 75 emits
            # during the #1477 outage.
            echo "=== gate-coverage: REFUSED reason=exempt_without_owner scenario=$b ==="
            echo "gate.sh: REFUSED — '$b' is EXEMPT with a prose reason but no OWNER. Add a tracker ref (#NNNN or owner/repo#NNNN) or an until:YYYY-MM-DD expiry, so the exemption has to be re-justified rather than inherited (your-org/nexus-code#1486, same rule as #1482's none rows)." >&2
            refused=1
        fi
        exempt_names+=( "$b" )
    done <<< "$rows"

    rows=$(_gcov_rows gated) || { echo "=== gate-coverage: REFUSED reason=manifest_unreadable ==="; return 3; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        b=$(_gcov_field "$line" 2)
        gated_names+=( "$b" )
        st=$(_gcov_field "$line" 3)
        tr=$(_gcov_field "$line" 4)
        while IFS= read -r m || [[ -n "$m" ]]; do
            [[ -n "$m" ]] || continue
            cov_pane+=( "$m" )
            # R5: the declaration may not name a member outside the DERIVED
            # vocabulary. A manifest that claims coverage of a state the tool
            # does not have is a manifest that has drifted, and its other
            # claims are then unbacked too.
            if ! _gcov_has "$m" ${v_pane[@]+"${v_pane[@]}"}; then
                echo "=== gate-coverage: REFUSED reason=undeclared_state scenario=$b member=$m ==="
                echo "gate.sh: REFUSED — '$b' declares pane-state '$m', which monitor/pane-state.sh --states does not have. The declaration has drifted from the vocabulary." >&2
                refused=1
            fi
            # R7: the OVER-CLAIM FALSIFIER. Necessary, not sufficient, and
            # deliberately PERMISSIVE (a member named only in a comment
            # passes). It exists to catch an invented claim, not to verify a
            # true one — do not read a pass here as evidence of coverage.
            if [[ -n "${GCOV_SCENARIO_DIR:-}" || -f "$_gcov_repo/monitor/watcher/test-integration/$b" ]]; then
                local sf="${GCOV_SCENARIO_DIR:-$_gcov_repo/monitor/watcher/test-integration}/$b"
                if [[ -r "$sf" ]] && ! grep -qF -- "$m" "$sf"; then
                    echo "=== gate-coverage: REFUSED reason=overclaimed_member scenario=$b member=$m ==="
                    echo "gate.sh: REFUSED — '$b' is declared to cover '$m', but that token does not appear in the file at all." >&2
                    refused=1
                fi
            fi
        done < <(_gcov_split_csv "$st")
        while IFS= read -r m || [[ -n "$m" ]]; do
            [[ -n "$m" ]] || continue
            cov_deliv+=( "$m" )
            if ! _gcov_has "$m" ${v_deliv[@]+"${v_deliv[@]}"}; then
                echo "=== gate-coverage: REFUSED reason=undeclared_transport scenario=$b member=$m ==="
                echo "gate.sh: REFUSED — '$b' declares delivery transport '$m', which no monitor/harness adapter declares." >&2
                refused=1
            fi
        done < <(_gcov_split_csv "$tr")
    done <<< "$rows"

    # ---- R4: every EXECUTED-population member must be declared ----
    for s in "${prod[@]}"; do
        b=$(basename "$s")
        if ! _gcov_has "$b" ${gated_names[@]+"${gated_names[@]}"}; then
            echo "=== gate-coverage: REFUSED reason=gated_but_undeclared scenario=$b ==="
            echo "gate.sh: REFUSED — '$b' is in the gate's scenario list but declares no coverage, so the coverage figure below would not describe the run." >&2
            refused=1
        fi
    done

    # ---- R6: THE RATCHET — every realmodel file on disk is gated or exempt ----
    local sdir="${GCOV_SCENARIO_DIR:-$_gcov_repo/monitor/watcher/test-integration}"
    local -a on_disk=() on_disk_paths=()
    if [[ -d "$sdir" ]]; then
        # A glob, not `ls | grep`: this host's `find`/`grep` are shell
        # FUNCTIONS in interactive shells and a rejected argument comes back as
        # a silent zero (CLAUDE.md). The `-r` guard covers the unmatched-glob
        # case in both nullglob modes, so an empty directory reaches the
        # vacuity check below rather than smuggling the literal pattern in.
        local _f
        for _f in "$sdir"/test-realmodel-*.sh; do
            [[ -r "$_f" ]] || continue
            on_disk+=( "$(basename "$_f")" )
            on_disk_paths+=( "$_f" )
        done
    fi
    gate_refuse_if_vacuous "on-disk realmodel scenarios" "${#on_disk[@]}" \
        "nothing matched test-realmodel-*.sh under $sdir — the ratchet has no population to ratchet, which is not the same as having nothing to say." \
        || refused=1
    # #1320: ONE untracked test-realmodel-*.sh takes the vacuity check above
    # from rc 3 REFUSED to rc 0 CLEARED. Measured. The scan is a filesystem
    # glob on purpose (an undeclared scenario must be SEEN), so the trackedness
    # question is asked here rather than by narrowing the glob.
    if (( ${#on_disk_paths[@]} )); then
        gcov_refuse_if_untracked "on-disk realmodel scenarios" "$_gcov_repo" \
            "${on_disk_paths[@]}" || refused=1
    fi
    for b in "${on_disk[@]}"; do
        if ! _gcov_has "$b" ${gated_names[@]+"${gated_names[@]}"} ${exempt_names[@]+"${exempt_names[@]}"}; then
            echo "=== gate-coverage: REFUSED reason=undeclared_scenario_file scenario=$b ==="
            echo "gate.sh: REFUSED — '$b' exists under $sdir and is neither GATED nor EXEMPT in $(gcov_manifest_path)." >&2
            echo "gate.sh: a scenario that exists but is not named is not gated, and was invisible in the tally (your-org/nexus-code#1261, #724)." >&2
            refused=1
        fi
    done

    (( refused == 0 )) || return 3

    # ---- the report ----
    local -a un_pane=() un_deliv=()
    for m in "${v_pane[@]}"; do
        _gcov_has "$m" ${cov_pane[@]+"${cov_pane[@]}"} || un_pane+=( "$m" )
    done
    for m in "${v_deliv[@]}"; do
        _gcov_has "$m" ${cov_deliv[@]+"${cov_deliv[@]}"} || un_deliv+=( "$m" )
    done

    # ── THE SURFACE AXIS (your-org/nexus-code#1344) ─────────────────────
    # A third population, DECLARED on both sides because a production surface
    # has no vocabulary to derive from: `surface` rows name the surfaces the
    # gate is meant to speak for (status `gated` or `known-gap`, with a
    # reason), and column 6 of a gated scenario row names the surfaces that
    # scenario DRIVES. A declared gap is visible; a surface merely absent from
    # a denominator is not (#1078's shape, the reason #1261 was filed). The
    # falsifier is the same permissive one the pane-state axis uses: a driven
    # surface whose basename never appears in the scenario file is refused.
    # Refusals, all fail-closed: an unknown status, a surface path that does
    # not exist, a gap with no reason, a scenario driving an undeclared
    # surface, a `gated` surface no scenario drives (a claim with nothing
    # behind it), a `known-gap` that IS driven (a stale declaration). ZERO
    # surface rows is not refused — a pre-#1344 manifest is legitimate — but
    # it is printed as NOT DECLARED, never as covered.
    local -a surf_paths=() surf_status=() surf_reason=() cov_surf=()
    local sroot="${GCOV_SURFACE_ROOT:-$_gcov_repo}" sp ss sr
    rows=$(_gcov_rows surface) || { echo "=== gate-coverage: REFUSED reason=manifest_unreadable ==="; return 3; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        sp=$(_gcov_field "$line" 2); ss=$(_gcov_field "$line" 3); sr=$(_gcov_field "$line" 5)
        case "$ss" in
            gated|known-gap) ;;
            *) echo "=== gate-coverage: REFUSED reason=surface_bad_status surface=$sp status=$ss ==="
               echo "gate.sh: REFUSED — surface '$sp' has status '$ss'; only gated|known-gap are defined (your-org/nexus-code#1344)." >&2
               refused=1 ;;
        esac
        if [[ ! -f "$sroot/$sp" ]]; then
            echo "=== gate-coverage: REFUSED reason=surface_missing surface=$sp ==="
            echo "gate.sh: REFUSED — surface '$sp' is declared but does not exist under $sroot; a coverage claim about a file that is not there is a claim about nothing." >&2
            refused=1
        fi
        if [[ "$ss" == known-gap && -z "${sr// /}" ]]; then
            echo "=== gate-coverage: REFUSED reason=surface_gap_without_reason surface=$sp ==="
            echo "gate.sh: REFUSED — surface '$sp' is a known-gap with no reason. A gap nobody had to justify is an omission with a row in front of it." >&2
            refused=1
        fi
        surf_paths+=( "$sp" ); surf_status+=( "$ss" ); surf_reason+=( "$sr" )
    done <<< "$rows"
    rows=$(_gcov_rows gated) || { echo "=== gate-coverage: REFUSED reason=manifest_unreadable ==="; return 3; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        b=$(_gcov_field "$line" 2)
        local sf; sf=$(_gcov_field "$line" 6)
        while IFS= read -r m || [[ -n "$m" ]]; do
            [[ -n "$m" ]] || continue
            cov_surf+=( "$m" )
            if ! _gcov_has "$m" ${surf_paths[@]+"${surf_paths[@]}"}; then
                echo "=== gate-coverage: REFUSED reason=undeclared_surface scenario=$b surface=$m ==="
                echo "gate.sh: REFUSED — '$b' drives surface '$m', which no \`surface\` row declares. Declare the surface, or the denominator is whatever nobody wrote down (your-org/nexus-code#1344)." >&2
                refused=1
            fi
            if [[ -n "${GCOV_SCENARIO_DIR:-}" || -f "$_gcov_repo/monitor/watcher/test-integration/$b" ]]; then
                local sf2="${GCOV_SCENARIO_DIR:-$_gcov_repo/monitor/watcher/test-integration}/$b"
                if [[ -r "$sf2" ]] && ! grep -qF -- "${m##*/}" "$sf2"; then
                    echo "=== gate-coverage: REFUSED reason=overclaimed_surface scenario=$b surface=$m ==="
                    echo "gate.sh: REFUSED — '$b' is declared to drive '$m', but '${m##*/}' does not appear in the file at all." >&2
                    refused=1
                fi
            fi
        done < <(_gcov_split_csv "$sf")
    done <<< "$rows"
    local -a un_surf=() gap_surf=()
    local i_s
    for i_s in "${!surf_paths[@]}"; do
        sp="${surf_paths[$i_s]}"; ss="${surf_status[$i_s]}"
        if _gcov_has "$sp" ${cov_surf[@]+"${cov_surf[@]}"}; then
            if [[ "$ss" == known-gap ]]; then
                echo "=== gate-coverage: REFUSED reason=surface_gap_is_driven surface=$sp ==="
                echo "gate.sh: REFUSED — surface '$sp' is declared a known-gap but a gated scenario drives it; the declaration is stale. Promote it to gated." >&2
                refused=1
            fi
        else
            if [[ "$ss" == gated ]]; then
                echo "=== gate-coverage: REFUSED reason=surface_gated_undriven surface=$sp ==="
                echo "gate.sh: REFUSED — surface '$sp' is declared gated but no gated scenario drives it; a covered surface with nothing behind it is the claim this axis exists to refuse." >&2
                refused=1
            fi
            un_surf+=( "$sp" ); gap_surf+=( "$sp (${surf_reason[$i_s]:-no reason})" )
        fi
    done
    (( refused == 0 )) || return 3
    local n_pane_cov=$(( ${#v_pane[@]} - ${#un_pane[@]} ))
    local n_del_cov=$(( ${#v_deliv[@]} - ${#un_deliv[@]} ))
    local n_surf_cov=$(( ${#surf_paths[@]} - ${#un_surf[@]} ))

    echo "=== gate-coverage: pane-state ${n_pane_cov}/${#v_pane[@]} covered ==="
    echo "    vocabulary: monitor/pane-state.sh --states (derived, never hand-enumerated)"
    (( ${#un_pane[@]} > 0 )) && echo "    UNCOVERED:  ${un_pane[*]}"
    echo "=== gate-coverage: delivery ${n_del_cov}/${#v_deliv[@]} covered ==="
    echo "    vocabulary: monitor/harness/*.sh transports (derived, as monitor/send.sh does)"
    (( ${#un_deliv[@]} > 0 )) && echo "    UNCOVERED:  ${un_deliv[*]}"
    if (( ${#surf_paths[@]} == 0 )); then
        echo "=== gate-coverage: surfaces NOT DECLARED (0 surface rows) — the production-surface axis is UNMEASURED, not covered (your-org/nexus-code#1344) ==="
    else
        echo "=== gate-coverage: surfaces ${n_surf_cov}/${#surf_paths[@]} covered ==="
        echo "    declared: \`surface\` rows of $(gcov_manifest_path) (DECLARED on both sides — a production surface has no vocabulary to derive from)"
        (( ${#un_surf[@]} > 0 )) && echo "    KNOWN GAPS: $(printf '%s; ' "${gap_surf[@]}")"
    fi
    echo "=== gate-coverage: scenarios gated=${#gated_names[@]} exempt=${#exempt_names[@]} on-disk=${#on_disk[@]} ==="
    (( ${#exempt_names[@]} > 0 )) && echo "    EXEMPT (exist, not gated): ${exempt_names[*]}"
    echo "=== gate-coverage: boundary — a GREEN below is a claim about the COVERED members only; the UNCOVERED lines above are what it does NOT say ==="
    return 0
}
