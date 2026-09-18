#!/usr/bin/env bash
# undefined-helper-lint.sh — a suite must not call a helper nothing defines.
#
# your-org/nexus-code#922, the STATIC half.
#
# THE DEFECT. A suite that sources `_test_helpers.sh` and calls a helper that
# neither it nor the helper file defines exits 127 for that call, is counted by
# NOTHING, prints no failure, and reports success for a check that never ran.
# The assertion-count floor cannot see it: a 127 leaves no trace in the verdict
# OR the count, so the total is one lower than the author believes with no
# baseline to compare against.
#
# WHY A LINT AND NOT ONLY THE RUNTIME HANDLER. `command_not_found_handle` in
# `_test_helpers.sh` catches `assert_*`, `th_*`, and the four measured
# assertion-shaped names (`ok`, `bad`, `pass`, `fail`). It can only ever fire
# for names somebody enumerated, and at call time an unknown missing name is
# indistinguishable from a deliberately-absent binary — several suites invoke
# absent binaries on purpose, and breaking those would be a worse trade.
#
# This lint answers the general case from the other side: it DERIVES the
# cross-suite name population from the corpus instead of from a list. Any name
# that some suite defines as a function, and that this file's exports do not
# cover, is a name that "looks available" to somebody moving between suites —
# which is precisely the mechanism by which `#922` happened (`ok`/`bad` are
# defined locally in test-skeptic-channel.sh, so they look like shared helpers
# from anywhere else).
#
# THE POPULATION IS EVERY SUITE, AND MEMBERSHIP IS NOT THE PREDICATE
# (your-org/nexus-code#1364). Both halves of `#922`'s remedy used to key on ONE
# membership test — does the suite `source _test_helpers.sh` — because the
# runtime handler is defined inside that file and the lint drew its population
# from the same predicate. A suite outside that set was checked by NEITHER
# half: measured at `bbf8985b`, 188 of 412 suites, and 50 of the 64 suites that
# define their own `ok()`/`bad()` were among them — exactly the shape #922's
# body names (a local `ok` makes the name look available from anywhere). A
# bare `ok "planted"` in any of them printed `ALL TESTS PASSED`, rc 0, with one
# line of stderr. It fired again while this was being written: a `check`
# helper pasted into `test-trash-install.sh` above its own definition, six
# `command not found` lines, green footer.
#
# So the population is every tracked `test-*` under monitor/ that
# `shf_is_shell` accepts, and "sources the helper" becomes a PER-FILE flag
# that decides only whether the helper's exports are REACHABLE there. Each
# call site is resolved against that suite's OWN definitions, plus the
# definitions of every `source` it names that the resolver can follow
# (variable-indirect included — `. "$HELPERS"` with `HELPERS=…/_test_helpers.sh`
# assigned in the same file is the `test-case-skip-propagation.sh` shape that
# turned 30 legitimate `assert_*` calls into false positives for a
# line-anchored predicate), plus the helper's exports iff the suite — or a
# library it sources — sources the helper.
#
# ADVISORY FIRST, AND THE POLARITY IS PER AXIS. The widening adds TWO axes and
# both are advisory until measured: (1) call sites in NON-SOURCING suites, and
# (2) candidate NAMES that only a non-sourcing suite defines — the widened
# candidate universe. The pre-#1364 verdict — a call in a helper-SOURCING suite
# to a name some other helper-SOURCING suite defines — is unchanged and still
# exits 1. Everything the widening adds is printed under an ADVISORY heading,
# COUNTED in the summary line, and does NOT flip the exit unless `--strict`
# (or `UHL_STRICT=1`) is given. A guard that arrives red on ~190 files owned
# by other agents gets suppressed rather than argued with, and a suppressed
# guard is no guard; the count is published on every run so the flip is a
# measured decision rather than a hope.
#
# MEASURED AT 741191c8, and this is why the widened axes are NOT strict yet:
# 454 suites, 261 sourcing / 193 not; 19 ADVISORY call sites in 6 suites, and
# on inspection EVERY ONE is a false positive of two shapes the scanner cannot
# see through — a call-shaped line inside a MULTI-LINE QUOTED STRING (a fixture
# body passed as an argument: test-paste-dead-pane-guard-arms.sh,
# test-filter-skip-marker.sh, test-sigpipe-assertion-lint.sh), and a function
# DEFINED BY `eval` of text extracted from another file at runtime
# (`eval "$(_extract_fn "$MAIN_SH" _emit_delivery_fail)"`,
# `respawn_agent_body=$(awk '…')`: test-watcher-robustness.sh, test-respawn.sh).
# The widened universe is what turned those lines into candidates. Flipping
# to strict before a quote-aware call scan and an eval-extraction exclusion
# would red six legitimate suites; until then `--strict` is the measurement
# arm, not the gate. Re-measure before flipping: the number is a property of
# the tree.
#
# SCOPE, stated because a boundary drawn narrower than its mechanism is the
# defect this whole file is about:
#   - It checks CALL SITES in command position at the start of a line, WITH AN
#     ARGUMENT — including flag-first (`ck -v x`) and path-first (`ck /tmp/x`).
#     `#939` F2 measured the first draft at 2 of 7 shapes; this is 4 of 7.
#   - A BARE call with no argument (`ck` alone on a line) is NOT matched, and
#     that is deliberate: adding it flagged Python's `pass` statement inside
#     `python3 -c "…"` blocks, which heredoc-stripping does not reach. The
#     residue is real and is named here rather than implied away.
#   - It does NOT parse shell. A call inside `$( )`, after `&&`, or built by
#     `eval` is invisible to it. It is a ratchet against the common shape, not
#     a proof of absence.
#   - THE ONE-LINER `if …; then <helper> "x"; fi` IS ALSO INVISIBLE, and for a
#     stated reason (your-org/nexus-code#1364 rider): the call-site scan takes
#     the FIRST lowercase word on the line, so that line yields the name `if`,
#     never `ok`. Structurally the same residue as the `&&` residue above — a
#     helper reached other than in first-command position — and named here
#     rather than implied by it.
#   - A `source` it cannot resolve to a file makes the calling suite's
#     unreachable names UNKNOWN, not UNDEFINED, and the count is printed on
#     every run. See "UNRESOLVED IS NOT UNDEFINED" at the resolver below —
#     that distinction is `#989`, and it is the difference between a lint and
#     a confident wrong answer.
#   - It only knows names that are defined SOMEWHERE in the corpus. A typo that
#     matches no existing helper name (`assert_eqq`) is caught by the RUNTIME
#     handler instead, via the `assert_*` prefix — the two halves cover
#     different populations and neither subsumes the other.
#
# FAILS LOUD WHEN IT CANNOT LOOK (your-org/nexus-code#906 B). If the suite
# enumeration or the name enumeration comes back empty, that is reported as a
# REFUSAL (exit 2), never as a clean pass. A checker that silently finds nothing
# is the same defect it is looking for.
#
# THE UNKNOWN RESIDUE IS RATCHETED (your-org/nexus-code#1030 F2). Before this,
# NOTHING could tell `UNKNOWN` from clean. `UNKNOWN` keeps `rc 0` by design and
# the summary line always contains the word `suites`, and those two facts were
# exactly what the lint's only real-corpus consumer asserted — both hold
# identically at `0 UNKNOWN` and at `N UNKNOWN`. The `%d UNKNOWN` field this
# lint prints was read by nobody. Composed with F1 above, that is coverage
# decay with no red: a mechanism by which the exempt set grows from TEXT, and
# nothing objecting when it does. The composition is not hypothetical — it
# executed once already, inside `#989` itself.
#
# So the set is DATA. `--unknown-set` emits `<file>\t<name>` rows, and a normal
# run compares them against `uhl-unknown-callsites.manifest`, failing on
# disagreement in EITHER direction.
#
#   * Keyed on the CALL-SITE list, not on the unresolved-SOURCE set. An offence
#     planted in a file ALREADY carrying an unresolvable source adds no source
#     directive, so that set is unchanged while `UNKNOWN` goes 0 -> 1 — a
#     source-set ratchet would not have caught the very mutant that motivates
#     having one.
#   * Keyed on `<file>\t<name>`, not `file:line`. Line numbers churn on every
#     unrelated edit, and a noisy ratchet gets regenerated reflexively, which is
#     how a ratchet stops ratcheting.
#   * `aso-unresolved-sources.manifest` is the same mechanism one guard over,
#     for the identical construct — `test-fixture-reap-ownership.sh  $1` sits in
#     both that manifest and this residue.
#
# Usage:
#   bash monitor/watcher/undefined-helper-lint.sh              # lint (advisory on non-sourcing suites)
#   bash monitor/watcher/undefined-helper-lint.sh --strict     # …and exit 1 on a non-sourcing offence too
#   bash monitor/watcher/undefined-helper-lint.sh --population # list suites (EVERY suite, #1364)
#   bash monitor/watcher/undefined-helper-lint.sh --population-sourcing
#       # the subset that sources _test_helpers.sh (the pre-#1364 population;
#       # a diagnostic, never the gate)
#   bash monitor/watcher/undefined-helper-lint.sh --unknown-set
#       # emit the UNKNOWN residue as `<file>\t<name>` rows; redirect into
#       # monitor/watcher/uhl-unknown-callsites.manifest to regenerate it.
#       # REGENERATING IS NOT A FIX — see the manifest's own header.
#
# Exit: 0 clean (advisory offences, if any, are printed and counted)
#     · 1 offending call site(s) in a helper-SOURCING suite, or in ANY suite
#       under --strict · 2 REFUSED (could not look)
#     · 4 the UNKNOWN residue disagrees with the manifest
#
# 4 is deliberately NOT 1. This file already insists that a REFUSAL must not be
# mistaken for a FINDING; a residue that moved is a third thing again, and
# collapsing it onto `1` would re-blur the distinction `#906 B` drew.

set -uo pipefail

_lint_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_lint_dir/../.." && pwd)
cd "$REPO_ROOT" || { echo "undefined-helper-lint: cannot cd to repo root" >&2; exit 2; }

HELPER="monitor/watcher/_test_helpers.sh"
[[ -r "$HELPER" ]] || { echo "undefined-helper-lint: REFUSED — $HELPER unreadable" >&2; exit 2; }

MODE="${1:-}"
STRICT=0
if [[ "$MODE" == "--strict" ]]; then STRICT=1; MODE=""; fi
[[ "${UHL_STRICT:-0}" == "1" ]] && STRICT=1
# Overridable so a FIXTURE corpus can carry its own residue, and — the reason
# that matters — so the ratchet's own potency can be driven by varying the
# MANIFEST while holding the corpus constant. That is the axis the mechanism
# varies on; mutating the corpus instead would test the resolver, not the
# ratchet.
UNKNOWN_MANIFEST="${UHL_UNKNOWN_MANIFEST:-monitor/watcher/uhl-unknown-callsites.manifest}"

# ── Population: suites that source the helper ──────────────────────────────
# `git ls-files` pathspecs ARE globs; `git ls-tree` pathspecs are path
# prefixes and would return a confident zero here (CLAUDE.md, #770).
mapfile_guard=$(git ls-files -- 'monitor/**/*.sh' 'monitor/*.sh' 2>/dev/null | wc -l)
if (( mapfile_guard == 0 )); then
    echo "undefined-helper-lint: REFUSED — git ls-files returned no shell files at all." >&2
    echo "  Not a clean result: the enumeration did not run." >&2
    exit 2
fi
# your-org/nexus-code#939 F4 — `grep -l '_test_helpers.sh'` matches any file
# that MENTIONS the string, including in a comment or a lint pattern. At
# `d102a7f` that is 145 files, of which only 133 actually SOURCE the helper;
# the 12 extras are `run-tests.sh`, `uncounted-abort-lint.sh`,
# `early-exit-readers.sh`, the helper itself, and `test-cc-auto-update.sh`
# (which says in so many words that it does not source it).
#
# The distinction is not cosmetic here: this lint treats the helper's 37
# exports as REACHABLE in every member of the population, so a mention-only
# file would have `assert_eq` scored reachable when it is not. That errs
# toward not flagging — a soundness hole rather than a false positive — but it
# is one the population claim would have concealed.
#
# So require an actual source operator: `. <path>` or `source <path>`, allowing
# a leading `&&`/`||` and a variable-indirect path.
# Three spellings, because the path frequently contains SPACES —
# `. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"` — so a
# `[^[:space:]]*` path pattern silently under-counts (measured: 102 of 133).
_uhl_direct='^[[:space:]]*(\.|source)[[:space:]].*_test_helpers\.sh'
_uhl_chained='(&&|\|\||;)[[:space:]]*(\.|source)[[:space:]].*_test_helpers\.sh'
# _uhl_sources_helper <file> — does this file SOURCE the helper (three
# spellings, above)? A per-file FLAG since #1364, no longer the population.
_uhl_sources_helper() {
    [[ -r "$1" ]] || return 1
    grep -qE "$_uhl_direct" "$1" 2>/dev/null && return 0
    grep -qE "$_uhl_chained" "$1" 2>/dev/null && return 0
    # variable-indirect: HELPERS=".../_test_helpers.sh" … then `. "$HELPERS"`
    grep -qE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*_test_helpers\.sh' "$1" 2>/dev/null \
        && grep -qE '^[[:space:]]*(\.|source)[[:space:]]+"?\$' "$1" 2>/dev/null && return 0
    return 1
}

# THE POPULATION: every tracked `test-*` under monitor/ that is a SHELL FILE by
# the shared predicate (your-org/nexus-code#1364). `shf_is_shell` rather than a
# `*.sh` glob, because a filename glob is exactly how an enumeration missed the
# extensionless main CLI once (#1214); `git ls-files` pathspecs are globs and
# `*` crosses `/`, so `monitor/**` is the whole subtree (#954). The classifier
# lives in monitor/shell-files.sh; a fixture corpus must carry it, as the
# honesty suite's does.
_uhl_shf="$REPO_ROOT/monitor/shell-files.sh"
if [[ ! -r "$_uhl_shf" ]]; then
    echo "undefined-helper-lint: REFUSED — $_uhl_shf unreadable; cannot classify shell files." >&2
    exit 2
fi
# shellcheck source=monitor/shell-files.sh
. "$_uhl_shf" >/dev/null 2>&1 || { echo "undefined-helper-lint: REFUSED — could not source $_uhl_shf" >&2; exit 2; }
if ! declare -F shf_is_shell >/dev/null 2>&1; then
    echo "undefined-helper-lint: REFUSED — shf_is_shell is not defined after sourcing $_uhl_shf" >&2
    exit 2
fi
SUITES=$(git ls-files -- 'monitor/**' 2>/dev/null \
         | while IFS= read -r _f; do
               case "${_f##*/}" in test-*) ;; *) continue ;; esac
               [[ -r "$_f" ]] || continue
               shf_is_shell "$_f" 2>/dev/null || continue
               printf '%s\n' "$_f"
           done | sort -u)
N_SUITES=$(printf '%s\n' "$SUITES" | grep -c . )
SOURCING=$(printf '%s\n' "$SUITES" | while IFS= read -r _f; do
               [[ -n "$_f" ]] || continue
               _uhl_sources_helper "$_f" && printf '%s\n' "$_f"
           done)
N_SOURCING=$(printf '%s\n' "$SOURCING" | grep -c . )

if [[ "$MODE" == "--population" ]]; then
    printf '%s\n' "$SUITES"
    exit 0
fi
if [[ "$MODE" == "--population-sourcing" ]]; then
    printf '%s\n' "$SOURCING"
    exit 0
fi

if (( N_SUITES == 0 )); then
    echo "undefined-helper-lint: REFUSED — zero test suites classified as shell under monitor/." >&2
    echo "  That is not a clean population, it is a failed enumeration." >&2
    exit 2
fi
if (( N_SOURCING == 0 )); then
    echo "undefined-helper-lint: REFUSED — zero suites source $HELPER." >&2
    echo "  The helper's exports would be reachable nowhere; the sourcing predicate did not run." >&2
    exit 2
fi

# ── Names the helper EXPORTS ───────────────────────────────────────────────
EXPORTED=$(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$HELPER" | tr -d '()' | sort -u)
N_EXPORTED=$(printf '%s\n' "$EXPORTED" | grep -c . )
if (( N_EXPORTED == 0 )); then
    echo "undefined-helper-lint: REFUSED — parsed zero function definitions from $HELPER." >&2
    echo "  The extractor did not run; every comparison below would be vacuous." >&2
    exit 2
fi

# ── Names some suite defines locally that the helper does NOT export ───────
# These are the "looks available" names: shared-looking, not actually shared.
#
# THREE EXCLUSIONS, each added because the first draft produced ~130 false
# positives against a corpus with ZERO real instances. That matters more than
# the count: a lint that fails legitimate suites is disabled by the first person
# under time pressure, which removes it entirely — so a false positive here is
# not a cosmetic problem, it is the whole guard.
#
#   1. REAL COMMANDS. `timeout` is defined as a shim function in 7 suites, so it
#      entered the candidate set, and every legitimate `timeout ...` call in
#      every other suite was then flagged. A name that resolves on PATH is not a
#      missing helper.
#   2. SOURCED LIBRARIES, resolved by BASENAME. `wait_for` lives in
#      `test-integration/_harness.sh` and `monitor/cc-harness/_lib.sh`; suites
#      reach it through `. "$_test_dir/_harness.sh"`, a path this cannot expand.
#      Resolving the basename anywhere under monitor/ is cruder than expanding
#      the variable and errs toward NOT flagging, which is the right direction
#      for a ratchet.
#   3. HEREDOC BODIES. A fixture that writes a suite is text, not code. The
#      helper already ships `th_strip_heredocs` for exactly this, sharing one
#      quote state machine with `uncounted-abort-lint.sh`; using it rather than
#      a second regex is the point of that function existing.
#
#      HOW FAR THE STRIP REACHES, stated because the gap between two of these
#      scans WAS the defect (your-org/nexus-code#1030 F1). Every per-file scan
#      now reads ONE stripped body: the SOURCE directives, the file's OWN
#      definitions, the CALL sites, and the fourth exclusion's
#      `<name>() {` lookup. Previously only the call scan did, so inert
#      fixture text could make a name look reachable, could satisfy the
#      exclusion, and — the one that mattered — could exempt the whole file.
#
#      WHERE IT STOPS, and this is a declared boundary, not an oversight:
#      `LOCAL_NAMES` above harvests the CANDIDATE UNIVERSE across the whole
#      corpus with one `xargs grep` over RAW files, so a name defined only
#      inside a heredoc is still a candidate. That errs toward MORE candidates
#      and therefore toward flagging more, which is the safe direction for the
#      universe (the per-file scans decide what is actually reported). Stripping
#      it too was measured at `3458180` and changes nothing today — 169 suites,
#      636 names, 0 offences, 0 UNKNOWN either way — so it is left raw for its
#      cost (169 strips) rather than for a reason, and this sentence is here so
#      the next author does not have to re-derive that.
# TWO UNIVERSES (#1364). `CANDIDATES` is harvested from EVERY suite — the
# widened universe. `CANDIDATES_STRICT` is the pre-#1364 universe, harvested
# from the SOURCING suites only, and it is what the gated verdict still keys
# on: a name that only a non-sourcing suite defines is a NEW axis, and a call
# to it (from any suite) is advisory until measured. Same exclusions, both.
EXCLUDED_REAL=0
_uhl_harvest() {   # <newline-separated file list> -> local function names, one per line
    printf '%s\n' "$1" | xargs -r grep -hoE '^[[:space:]]*[a-z_][a-z0-9_]*\(\)' 2>/dev/null \
        | tr -d '() \t' | sort -u
}
_uhl_filter() {    # <names> -> those neither exported nor real commands; counts the excluded
    local nm
    while IFS= read -r nm; do
        [[ -n "$nm" ]] || continue
        grep -qx -- "$nm" <<<"$EXPORTED" && continue
        if command -v -- "$nm" >/dev/null 2>&1; then
            EXCLUDED_REAL=$(( EXCLUDED_REAL + 1 )); continue
        fi
        printf '%s\n' "$nm"
    done <<<"$1"
}
LOCAL_NAMES=$(_uhl_harvest "$SUITES")
CANDIDATES=$(_uhl_filter "$LOCAL_NAMES")
N_CAND=$(printf '%s\n' "$CANDIDATES" | grep -c . )
_excl_all=$EXCLUDED_REAL; EXCLUDED_REAL=0
CANDIDATES_STRICT=$(_uhl_filter "$(_uhl_harvest "$SOURCING")")
N_CAND_STRICT=$(printf '%s\n' "$CANDIDATES_STRICT" | grep -c . )
EXCLUDED_REAL=$_excl_all
if (( N_CAND == 0 )); then
    echo "undefined-helper-lint: REFUSED — derived zero cross-suite names." >&2
    echo "  The corpus defines local helpers; extracting none means the parse failed." >&2
    exit 2
fi

# basename -> path index, so `. "$_test_dir/_harness.sh"` resolves.
declare -A LIBPATH=()
while IFS= read -r lf; do
    [[ -n "$lf" ]] || continue
    LIBPATH["$(basename "$lf")"]="${LIBPATH[$(basename "$lf")]:-}${lf} "
done < <(git ls-files -- 'monitor/**/*.sh' 'monitor/*.sh' 2>/dev/null)
(( ${#LIBPATH[@]} > 0 )) || {
    echo "undefined-helper-lint: REFUSED — built an empty library index." >&2; exit 2; }

# ── The check ──────────────────────────────────────────────────────────────
#
# ONE pass per file, not one grep per (file, name). The naive form is 143
# suites x ~100 candidate names = ~14k greps and does not finish in a useful
# time; a lint nobody waits for is a lint nobody runs.
offences=0
adv_offences=0
ADVISORY_LIST=""
unknowns=0
UNKNOWN_LIST=""
blind_advisory=0
BLIND_ADVISORY_LIST=""
# ASSOCIATIVE ARRAYS, NOT PER-NAME GREPS (your-org/nexus-code#1364). The check
# below used to run TWO `grep -qx` processes per call site — one against the
# reachable set, one against the candidate file — and at ~13,000 call sites
# over the widened population that was the whole runtime (measured 372 s at
# load 47 for 454 suites, against 150 s for 263 before the widening). The
# strip itself is ~80 ms per 2,000-line file. A lint nobody waits for is a
# lint nobody runs, so the lookups are hash probes now.
declare -A IS_CAND=() IS_STRICT_CAND=()
while IFS= read -r _cn; do [[ -n "$_cn" ]] && IS_CAND["$_cn"]=1; done <<<"$CANDIDATES"
while IFS= read -r _cn; do [[ -n "$_cn" ]] && IS_STRICT_CAND["$_cn"]=1; done <<<"$CANDIDATES_STRICT"

# th_strip_heredocs lives in the helper; source it for that one function.
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$HELPER" >/dev/null 2>&1 || true

# ── UNRESOLVED IS NOT UNDEFINED (your-org/nexus-code#989) ───────────────────
#
# The resolver used to extract a source path with `[^[:space:];&|]+`, which
# TRUNCATES AT THE FIRST SPACE. The header 130 lines above already knew paths
# here contain spaces — that is precisely why the POPULATION regex uses `.*` —
# but the resolver never got the same treatment, so
# `. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"` yielded the token
# `$(dirname` and resolved to nothing at all.
#
# Measured at the `dev`+`#989` union (372070c merged with ac0c4f3):
# **135 of 323 source directives — 42% — across 63 of 157 suites — 40% —
# failed to resolve**, 48 of them to that single truncation and 20 more to a
# bare `. "$LIB"`.
#
# The count is not the defect. What the lint DID with it is: an UNRESOLVED
# source was indistinguishable from a file that sources NOTHING, so every name
# behind one was reported `not defined here, not reachable, not exported`. That
# is a confident UNDEFINED manufactured by a failed LOOKUP — this repo's
# signature defect wearing the opposite sign. It fired on
# `test-remote-instrument-potency.sh:301`, where `_remote_identity_probe` is
# defined at `monitor/_remote_lib.sh:1389`, `LIB` is exported at line 98, and
# `type -t` answers `function` at runtime. The lint was not wrong about the
# corpus; it was wrong about itself.
#
# TWO FIXES, and they answer DIFFERENT QUESTIONS — which is why neither alone
# is the answer:
#
#   (1) RESOLVE what is resolvable. Take the basename named ANYWHERE on the
#       directive line — the same basename-indexed crudity the header already
#       declares for `. "$_test_dir/_harness.sh"` — and chase ONE variable hop
#       (`. "$LIB"` with `LIB="$MON_DIR/_remote_lib.sh"` in the same file) when
#       the line names no `.sh` itself. Both err toward resolving MORE, hence
#       toward NOT flagging, which is this lint's declared direction.
#
#   (2) For the residue that NO static resolver can follow — `. "$1"` inside a
#       function, `. "$WORK/mutant.sh"` naming a fixture written at runtime —
#       report UNKNOWN rather than UNDEFINED, and print the count on every run.
#
# (2) alone would have been the tidy answer and would have gutted the lint:
# before (1), 40% of the corpus carries an unresolvable source, so blanket
# "unknown" would have silently exempted a PLURALITY of the suites this exists
# to check. (1) shrinks the blind spot to a residue small enough that (2) is an
# honest disclosure instead of a hole. Order matters; the measurement is what
# says so.
#
# Exit stays 0 when the only residue is unknowns: the lint DID run, and it
# names what it could not see — the same treatment the header already gives
# bare calls and `eval`-built calls. Exit 2 remains reserved for "could not
# look AT ALL", which is a different claim.
_uhl_basename_on() {   # <text> -> last *.sh basename named in it, or empty
    printf '%s\n' "$1" | grep -oE '[A-Za-z0-9_][A-Za-z0-9_.-]*\.sh' | tail -1
}

blind=0
BLIND_LIST=""
UNKNOWN_SET=""

while IFS= read -r f; do
    [[ -n "$f" ]] || continue

    # ── ONE STRIP, BOTH SCANS (your-org/nexus-code#1030 F1) ────────────────
    #
    # The SOURCE scan used to read the RAW file while the CALL scan read
    # `th_strip_heredocs "$f"`, three lines apart. So INERT HEREDOC TEXT
    # decided whether a whole suite was CHECKED or EXEMPTED: fixture text
    # containing `source "$LIB"` sets `unresolved_here=1`, which downgrades
    # every finding in that file from UNDEFINED to UNKNOWN.
    #
    # The asymmetry is OLDER than `#989` — the source scan always read raw.
    # What `#989` changed is the CONSEQUENCE: an unresolved source used to
    # merely omit some names from `reachable`; it now decides the verdict. The
    # bug was latent and became load-bearing.
    #
    # It had already fired on THIS LINT'S OWN TEST SUITE. `#989` added a
    # `<<'FXC'` fixture to `test-helper-honesty.sh` whose body contains
    # `source "$LIB"` at column 0; that put the lint's own guard into the
    # exempt set, and a planted offence in it returned `rc 0, 1 UNKNOWN` where
    # the same line in a non-exempt suite returned `rc 1` naming the site. A
    # guard exempting itself, through a fixture added by the change under
    # review, invisible to author, reviewer and lint alike.
    #
    # Measured at `3458180`, using the lint's OWN resolver (one `printf`
    # inside it, so the population is this lint's and not a re-implementation):
    # 169 suites, **14** with `unresolved_here=1`, of which **3** change their
    # source-directive count under the stripper —
    # `test-ambient-shell-option-scope.sh` 25->3, `test-helper-honesty.sh`
    # 6->2, `test-version-restart.sh` 5->2. The other 11 are identical before
    # and after: their `. "$LIB"` lines sit inside `bash -c '…'` blocks, which
    # are not heredocs and which the stripper correctly leaves alone. Those
    # exemptions are legitimate. (`#806` is this same defect at another site,
    # and `th_strip_heredocs` is the remedy it produced; this applies that
    # remedy to the scan it was left out of.)
    #
    # NO SILENT FALLBACK. The old line was
    #     body=$(th_strip_heredocs "$f" 2>/dev/null) || body=$(cat "$f")
    # and that `||` is a silent revert to the RAW file. It defeats the fix
    # WITHOUT breaking its invariant — both scans still read the same text —
    # while the CONTENT goes back to raw, so F1 returns in full for that file
    # with NO SIGNAL AT ALL. A checker that could not look, reporting as though
    # it had, is this lint's own subject one layer down.
    #
    # So a strip failure is "could not look" FOR THAT FILE, and this lint
    # already owns that concept: REFUSED, exit 2, never a clean 0 (`#906 B`).
    # An EMPTY body from a NON-EMPTY file is the same claim by a different
    # route and is refused identically — the old `[[ -n "$body" ]] || continue`
    # dropped that file silently. Both arms are prospective: **0 of 169**
    # suites hit either at `3458180`.
    #
    # STDERR IS CAPTURED, NOT DISCARDED, and that is the third arm — found by
    # grepping this very change for a fresh instance of the class it closes.
    # `th_strip_heredocs` has a FAIL-SAFE path: on an UNTERMINATED heredoc it
    # prints `mis-parse suspected, emitting the file UNSTRIPPED` and exits
    # **0**. Fail-safe for its own contract, and a silent F1 for this caller —
    # rc says success, the content is raw, and `2>/dev/null` would throw away
    # the one signal saying so. Same shape as the `|| body=$(cat "$f")` this
    # change removes, arriving through the rc that was checked rather than the
    # one that was not.
    _strip_err=$(mktemp) || exit 2
    body=$(th_strip_heredocs "$f" 2>"$_strip_err"); _strip_rc=$?
    _strip_msg=$(head -c 400 "$_strip_err" 2>/dev/null); rm -f "$_strip_err"
    # AN UNRENDERABLE NON-SOURCING SUITE IS "NOT SCANNED", COUNTED, AND DOES
    # NOT REFUSE THE WHOLE RUN — in ADVISORY mode only (your-org/nexus-code#1364).
    # The widening brought in `test-assert-shims-wrapped.sh`, whose multi-line
    # awk program carries the literal `<<LAUNCHER` inside a regex; the shared
    # quote machine loses its state before that line (#1227's residue) and the
    # stripper emits the file UNSTRIPPED with a warning. Under the refuse-all
    # rule that one file turned every corpus verdict into exit 2, and a
    # widening that makes the lint refuse everywhere is a widening nobody
    # keeps. So: a SOURCING suite the stripper cannot render still REFUSES
    # (the gated half is unchanged); a NON-sourcing one is listed under its
    # own heading and counted in the summary line as unrenderable, and its
    # call sites are NOT judged — never scanned raw, which is the silent
    # fallback #1030 F1 removed. `--strict` restores the refusal for every
    # file, because a strict verdict needs the rendered body.
    _uhl_unrenderable() {   # <reason> — route by sourcing flag and mode
        if (( ! STRICT )) && ! _uhl_sources_helper "$f"; then
            blind_advisory=$(( blind_advisory + 1 ))
            BLIND_ADVISORY_LIST+="  ${f} — $1; NOT scanned (non-sourcing suite, advisory mode)"$'\n'
        else
            blind=$(( blind + 1 ))
            BLIND_LIST+="  ${f} — $1; this file was NOT scanned"$'\n'
        fi
    }
    if (( _strip_rc != 0 )); then
        _uhl_unrenderable "th_strip_heredocs exited ${_strip_rc}"
        continue
    fi
    if [[ -n "$_strip_msg" ]]; then
        _uhl_unrenderable "th_strip_heredocs warned and emitted the file UNSTRIPPED (rc 0): ${_strip_msg//$'\n'/ }"
        continue
    fi
    if [[ -s "$f" && -z "$body" ]]; then
        _uhl_unrenderable "th_strip_heredocs returned an EMPTY body for a NON-EMPTY file"
        continue
    fi
    [[ -n "$body" ]] || continue    # a genuinely empty file: nothing to check

    own=$(printf '%s\n' "$body" | grep -oE '^[[:space:]]*[a-z_][a-z0-9_]*\(\)' 2>/dev/null | tr -d '() \t' | sort -u)
    sourced=""
    unresolved_here=0
    # PER-FILE (#1364): the helper's exports are reachable here iff this file
    # sources the helper — or a library it sources does (one level; errs
    # toward reachable, the safe direction for a ratchet).
    sources_helper=0
    _uhl_sources_helper "$f" && sources_helper=1
    while IFS= read -r sline; do
        [[ -n "$sline" ]] || continue
        b=$(_uhl_basename_on "$sline")
        if [[ -z "$b" ]]; then
            # No literal `.sh` on the line — a bare `. "$LIB"`. Chase the
            # assignment in this same file, ONE hop, and try again.
            # `sed -n 1p`, NOT `| head -1`: this file sets `pipefail`, and a
            # `head` closes the pipe early, which puts the site on `#622`'s
            # early-exit-reader axis for no benefit. `sed -n 1p` drains.
            v=$(printf '%s\n' "$sline" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' \
                | sed -n '1p' | tr -d '${')
            [[ -n "$v" ]] && b=$(_uhl_basename_on \
                "$(grep -hE "^[[:space:]]*(export[[:space:]]+)?${v}=" "$f" 2>/dev/null | sed -n '1p')")
        fi
        if [[ -z "$b" || -z "${LIBPATH[$b]:-}" ]]; then
            unresolved_here=1
            continue
        fi
        for cand in ${LIBPATH[$b]}; do
            [[ -r "$cand" ]] || continue
            sourced+=$'\n'$(grep -oE '^[[:space:]]*[a-z_][a-z0-9_]*\(\)' "$cand" 2>/dev/null | tr -d '() \t')
            [[ "$b" == "_test_helpers.sh" ]] && sources_helper=1
            (( sources_helper )) || { _uhl_sources_helper "$cand" && sources_helper=1; }
        done
    done < <(printf '%s\n' "$body" \
             | grep -hE '^[[:space:]]*(\.|source)[[:space:]]|(&&|\|\||;|\()[[:space:]]*(\.|source)[[:space:]]' 2>/dev/null)
    # THE SECOND ALTERNATIVE (#1364): a `source` that is not the first word
    # of its line — `( NEXUS_STATE_DIR="$STATE"; source "$WD/_lib.sh"` inside a
    # subshell, or `… && . "$LIB"`. The POPULATION predicate above has accepted
    # the chained spelling since #939 F4; the per-file resolver did not, so a
    # library sourced that way was neither resolved nor UNKNOWN — simply not
    # seen — and every name behind it read as undefined. Measured at 741191c8
    # on `test-watcher-supervise.sh:236` (`_watcher_alive`, defined in the
    # `_lib.sh` sourced two lines above it). Errs toward resolving MORE.
    if (( sources_helper )); then
        reachable=$(printf '%s\n%s\n%s\n' "$own" "$sourced" "$EXPORTED" | sort -u)
    else
        reachable=$(printf '%s\n%s\n' "$own" "$sourced" | sort -u)
    fi
    declare -A REACH=()
    while IFS= read -r _rn; do [[ -n "$_rn" ]] && REACH["$_rn"]=1; done <<<"$reachable"
    # your-org/nexus-code#939 F2 — THE REGEX WAS NARROWER THAN THE HEADER.
    #
    # It required a first argument starting with a quote, `$`, or alphanumeric,
    # so `ck -v "x"` and `ck /tmp/x` were MISSED even though both sit at the
    # start of a line in command position — inside the stated rule and outside
    # the implementation. Measured 2 of 7 shapes caught. That is `#922`'s own
    # defect (a boundary narrower than the rule it states) reproduced inside
    # the fix for it, which is why the regex moves rather than the header.
    #
    # Now: flag-first (`ck -v x`) and path-first (`ck /tmp/x`) are IN.
    #
    # A BARE call at end-of-line is deliberately still OUT, and this boundary is
    # measured rather than assumed. `sk939` proposed adding an end-of-line
    # alternative; doing so flagged four sites in `test-remote-service.sh` — all
    # of them Python's `pass` statement inside an embedded `python3 -c "…"`
    # block. This corpus embeds Python in shell, `pass` is both a Python keyword
    # and one of the four assertion-shaped names, and `th_strip_heredocs`
    # removes heredocs, not quoted inline scripts. So the bare form cannot be
    # matched without re-importing false positives — which is the one failure
    # this lint cannot afford.
    #
    # That leaves 4 of 7 shapes from `#939` F2's table rather than 7 of 7. The
    # residue is stated in the header instead of being quietly implied: a bare
    # `ck`, and `$( )` / `&&`-chained / `eval`-built calls.
    called=$(printf '%s\n' "$body" | grep -nE '^[[:space:]]*[a-z_][a-z0-9_]*[[:space:]]+[-/["'"'"'$a-zA-Z0-9]' 2>/dev/null \
             | sed -E 's/^([0-9]+):[[:space:]]*([a-z_][a-z0-9_]*).*/\2 \1/')
    [[ -n "$called" ]] || continue

    while read -r name line; do
        [[ -n "$name" ]] || continue
        [[ -n "${REACH[$name]:-}" ]] && continue
        [[ -n "${IS_CAND[$name]:-}" ]] || continue
        # FOURTH EXCLUSION. A suite may pull a single function in by EXTRACTING
        # it: `source <(sed -n '/^_rt_declared_assertions() {/,/^}/p' "$RUNNER")`.
        # That is a process substitution, not a path, so no resolver can follow
        # it — but the file names the definition verbatim, which is the author
        # handling it deliberately. Any unanchored `<name>() {` in the file
        # counts as reachable. Errs toward NOT flagging, the right direction for
        # a ratchet: a missed offence is one this lint was never going to be the
        # last line of defence for, a false one gets the whole lint disabled.
        grep -qF -- "${name}() {" <<<"$body" && continue
        # UNRESOLVED IS NOT UNDEFINED — see the block above. This file sources
        # something no static resolver can follow, so the honest verdict for a
        # name we cannot place is "I could not determine it", not "it does not
        # exist". Counted and printed, never silently dropped.
        if (( unresolved_here )); then
            unknowns=$(( unknowns + 1 ))
            # The RATCHET KEY: file + name, never file:line (see the header).
            UNKNOWN_SET+="${f}"$'\t'"${name}"$'\n'
            UNKNOWN_LIST+="  ${f}:${line} calls \`${name}\` — UNKNOWN: this file has a \`source\` that no static resolver can follow"$'\n'
            continue
        fi
        # THE GATED VERDICT IS THE PRE-#1364 ONE: a sourcing suite, a name from
        # the sourcing universe. Either widened axis — a non-sourcing suite,
        # or a name only a non-sourcing suite defines — is ADVISORY: printed,
        # counted, never silently dropped, never exit 1 without --strict.
        _strict_site=0
        (( sources_helper )) && [[ -n "${IS_STRICT_CAND[$name]:-}" ]] && _strict_site=1
        (( STRICT )) && _strict_site=1
        if (( ! _strict_site )); then
            adv_offences=$(( adv_offences + 1 ))
            if (( sources_helper )); then
                _adv_why="a name only a NON-sourcing suite defines (widened universe)"
            else
                _adv_why="this suite does not source $HELPER (widened population)"
            fi
            ADVISORY_LIST+="  ${f}:${line} calls \`${name}\` — not defined here, not reachable; ${_adv_why} (ADVISORY; --strict makes it an offence)"$'\n'
            continue
        fi
        if (( offences == 0 )); then
            echo "undefined-helper-lint: a suite calls a helper NOTHING defines." >&2
            echo "  Such a call exits 127, is counted by nothing, and the suite reports" >&2
            echo "  success for a check that never ran (your-org/nexus-code#922)." >&2
            echo >&2
        fi
        printf '  %s:%s calls `%s` — not defined here, not reachable%s\n' \
            "$f" "$line" "$name" \
            "$( (( sources_helper )) && printf ', not exported' || printf ', and this suite does not source %s (--strict)' "$HELPER" )" >&2
        offences=$(( offences + 1 ))
    done <<<"$called"
done <<<"$SUITES"

# ── COULD NOT LOOK, PER FILE (your-org/nexus-code#1030 F1) ─────────────────
# Reported BEFORE offences and BEFORE the ratchet, because it invalidates
# both: a file the stripper could not render was never scanned, so neither a
# clean verdict nor an UNKNOWN set is complete over the population. Refusing
# here is the whole point — the shape being fixed is a checker that could not
# look reporting as though it had.
if (( blind_advisory > 0 )); then
    echo >&2
    echo "undefined-helper-lint: $blind_advisory NON-sourcing suite(s) could not be rendered and were NOT scanned (advisory mode, #1364):" >&2
    echo "  no verdict, advisory or otherwise, is claimed for them; --strict refuses the run instead." >&2
    printf '%s' "$BLIND_ADVISORY_LIST" >&2
fi
if (( blind > 0 )); then
    echo "undefined-helper-lint: REFUSED — $blind file(s) could not be rendered for scanning." >&2
    echo "  th_strip_heredocs failed or returned nothing for a non-empty file, so those" >&2
    echo "  files were NOT checked. This is NOT a clean result and NOT an offence; it is" >&2
    echo "  'could not look' (your-org/nexus-code#906 B), scoped to the files named." >&2
    echo >&2
    printf '%s' "$BLIND_LIST" >&2
    exit 2
fi

# The residue is printed on EVERY run, clean or not. A blind spot disclosed
# only when it happens to be empty is not a disclosure.
if (( unknowns > 0 )); then
    echo >&2
    echo "undefined-helper-lint: $unknowns call site(s) UNKNOWN — could not be determined," >&2
    echo "  because the calling suite sources a path this cannot resolve statically." >&2
    echo "  NOT reported as offences (your-org/nexus-code#989): an unresolved lookup is" >&2
    echo "  not evidence of absence. Listed so the gap is visible rather than implied." >&2
    echo >&2
    printf '%s' "$UNKNOWN_LIST" >&2
fi

# ADVISORY offences (#1364) are printed on EVERY run they occur, ahead of the
# verdict, so the count the polarity flip is waiting on is never a number
# nobody printed. Exit is unaffected here; `--strict` routes them above.
if (( adv_offences > 0 )); then
    echo >&2
    echo "undefined-helper-lint: ADVISORY — $adv_offences call site(s) on the WIDENED axes (a non-sourcing suite, or a" >&2
    echo "  name only a non-sourcing suite defines) name a helper nothing defines for them (your-org/nexus-code#1364). Such a call exits" >&2
    echo "  127, is counted by nothing, and the suite reports success. NOT an offence until the" >&2
    echo "  polarity flips (--strict / UHL_STRICT=1 makes it one now); listed so it is not silent." >&2
    echo >&2
    printf '%s' "$ADVISORY_LIST" >&2
fi

if (( offences > 0 )); then
    echo >&2
    echo "  Fix: define the helper in the suite, or call one $HELPER exports." >&2
    exit 1
fi

# ── THE RATCHET (your-org/nexus-code#1030 F2) ──────────────────────────────
# `LC_ALL=C sort -u` so the manifest is reproducible on a host that is not this
# one — the same reason test-early-exit-reader-manifest.sh and
# test-ambient-shell-option-scope.sh pin theirs, and the omission that reddened
# all six CI unit cells on one of their first pushes.
UNKNOWN_SORTED=$(printf '%s' "$UNKNOWN_SET" | LC_ALL=C sort -u | grep . || true)

if [[ "$MODE" == "--unknown-set" ]]; then
    printf '%s\n' "$UNKNOWN_SORTED" | grep . || true
    exit 0
fi

if [[ ! -r "$UNKNOWN_MANIFEST" ]]; then
    echo "undefined-helper-lint: REFUSED — cannot read $UNKNOWN_MANIFEST." >&2
    echo "  The UNKNOWN residue is ratcheted against that file; without it the" >&2
    echo "  residue goes unchecked, which is exactly the state #1030 F2 records." >&2
    echo "  Regenerate with: bash $0 --unknown-set > $UNKNOWN_MANIFEST" >&2
    exit 2
fi
RECORDED=$(grep -v '^#' "$UNKNOWN_MANIFEST" | grep . | LC_ALL=C sort -u || true)
if [[ "$UNKNOWN_SORTED" != "$RECORDED" ]]; then
    echo "undefined-helper-lint: the UNKNOWN residue disagrees with the manifest." >&2
    echo "  This is NOT an offence (exit 1) and NOT a refusal (exit 2). It is the" >&2
    echo "  set of call sites this lint declines to judge, and it MOVED." >&2
    echo "  REGENERATING IS NOT A FIX. Decide which happened:" >&2
    echo "    + MORE rows: a suite acquired a source no static resolver can follow," >&2
    echo "      and every name behind it is now unjudged. Is the source genuinely" >&2
    echo "      unfollowable, or is it inert HEREDOC TEXT? The second is #1030 F1" >&2
    echo "      and the answer is to move the fixture, not to record the row." >&2
    echo "    - FEWER rows: the resolver widened, or a suite was cleaned up. Good;" >&2
    echo "      regenerate and say which in the commit message." >&2
    echo "  Regenerate with: bash $0 --unknown-set > $UNKNOWN_MANIFEST" >&2
    diff <(printf '%s\n' "$RECORDED") <(printf '%s\n' "$UNKNOWN_SORTED") \
        | sed 's/^/    /' >&2 || true
    exit 4
fi

printf 'undefined-helper-lint: clean — %d suites (%d source the helper, %d do not; %s), %d cross-suite names (%d from sourcing suites, the gated universe; %d real commands excluded) vs %d exports, %d ADVISORY call site(s) on the widened axes, %d UNKNOWN call site(s) in %d manifest row(s), %d unrenderable non-sourcing suite(s) NOT scanned (ref %s)\n' \
    "$N_SUITES" "$N_SOURCING" "$(( N_SUITES - N_SOURCING ))" \
    "$( (( STRICT )) && printf 'STRICT' || printf 'advisory' )" \
    "$N_CAND" "$N_CAND_STRICT" "$EXCLUDED_REAL" "$N_EXPORTED" "$adv_offences" "$unknowns" \
    "$(printf '%s\n' "$RECORDED" | grep -c . )" "$blind_advisory" \
    "$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
exit 0
