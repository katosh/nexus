#!/usr/bin/env bash
# test-trap-bare-return-lint.sh — both-directions coverage for
# monitor/watcher/trap-bare-return-lint.sh (your-org/nexus-code#1513, the
# w234 round-1 SIGF finding).
#
# THE DEFECT, in one line: a bare `return` executed while a trap handler is
# running — in the handler or in ANY function it calls — reports the status of
# the last command BEFORE the trap fired (bash return.def), so a predicate that
# said "not mine" when called directly said "MINE" from a TERM trap and deleted
# another claimant's marker. Invisible to every direct-call unit test. The lint
# is the static half of the remedy; the SIGF case in
# test-cc-restart-watchdog-verify.sh is the dynamic half.
#
# A lint is only worth its maintenance if BOTH its directions are checked, so
# every case plants a fixture and says which direction it pins:
#
#   POSITIVE — a bare return in a function the walk MUST reach: the handler
#              itself, a callee, a callee across a `source`, each bare spelling,
#              and the REAL FILE with the fixed line MUTATED BACK — the mutation
#              check the lint owes: re-insert the fixed bare return and the lint
#              reddens NAMING the function and its trap chain.
#   NEGATIVE — explicit returns, an unreached function, `return` inside a
#              string or a quoted awk program, a comment naming the trap, the
#              reset forms, a name that is a SUBSTRING of a function's, a
#              call through a VARIABLE (the stated under-count).
#   ALLOWLIST — a row exempts exactly its site; a STALE row reddens; a row
#              with no reason REFUSES.
#   REFUSAL  — an empty population and a missing stripper dependency exit 3,
#              never 0: a corpus the lint could not read is not one it can
#              certify clean.
#   REAL TREE — clean, non-vacuous (population floor, the extensionless and
#              the dotfile members present), and the walk still REACHES the
#              function the measured defect lived in, by its chain. The lint
#              itself deliberately does not refuse on an empty reach — a tree
#              whose traps only `rm` reaches nothing, legitimately — so THIS is
#              where its potency is pinned.
#
# Fixtures are their OWN git repositories (the lint enumerates tracked files)
# and every git command against one is preceded by `th_require_fixture_repo`
# (your-org/nexus-code#1429): an empty or walked-up fixture path would aim git
# at the nexus itself, at rc 0.
#
# Run: bash monitor/watcher/test-trap-bare-return-lint.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Runtime is dominated by the two
# real-tree runs (each strips the whole shell corpus; ~30 s on a 36-core host).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LINT="$_test_dir/trap-bare-return-lint.sh"

# ---------------------------------------------------------------------------
# POPULATION DECLARATION (your-org/nexus-code#803, #1494). Above the first
# thing this suite prints, because `gp_handle` EXITS when it handles the flag.
# It forwards to the lint's OWN enumerator rather than keeping a copy, and
# names the files the lint reads to do its work: the shared shell predicate,
# the shared quote machine, its own classifier and the allowlist — an edit to
# any of them can change the verdict, and none is in `--files` by construction
# (two are awk, one is data). Declared at BIRTH: #1494 measured that the guards
# INVISIBLE to guards-for-diff were precisely the ones that caught real defects.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    bash "$LINT" --files "$REPO_ROOT"
    printf '%s\n' 'monitor/shell-files.sh' 'monitor/watcher/_shell_quotes.awk' \
        'monitor/watcher/_trap_bare_return.awk' 'monitor/watcher/trap-bare-return.allowlist' \
        'monitor/watcher/trap-bare-return-lint.sh'
}
gp_handle "$@"

[[ -r "$LINT" ]] || th_abort "missing $LINT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tbr-test-XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
NOALLOW="$WORK/no-such-allowlist"      # fixtures never read the real allowlist

# ---------------------------------------------------------------------------
# Fixture tree: its own git repo, carrying the two files the lint reads from
# <root> (the shared predicate it sources and the quote machine the stripper
# REFUSES without). Rebuilt from scratch per case so no plant leaks into the
# next case and answers through a path it was never written to reach.
_mktree() {
    rm -rf "$WORK/tree"
    mkdir -p "$WORK/tree/monitor/watcher"
    git init -q "$WORK/tree" || th_abort "git init failed"
    th_require_fixture_repo "$WORK/tree" "lint fixture"
    cp "$REPO_ROOT/monitor/shell-files.sh"            "$WORK/tree/monitor/"
    cp "$REPO_ROOT/monitor/watcher/_shell_quotes.awk" "$WORK/tree/monitor/watcher/"
}
# _plant <file-under-monitor/> <line…> — write one shell file into the fixture.
_plant() {
    local f="$1"; shift
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$WORK/tree/monitor/$f"
}
_track() {   # stage everything; the lint enumerates TRACKED files
    th_require_fixture_repo "$WORK/tree" "lint fixture"
    git -C "$WORK/tree" add -A >/dev/null 2>&1 || th_abort "git add failed in the fixture"
}
# _run [extra lint args…] — lint the fixture; stdout→$OUT, stderr→$ERR, rc→$RC
OUT=""; ERR=""; RC=""
_run() {
    _track
    bash "$LINT" --allowlist "${ALLOW:-$NOALLOW}" "$@" "$WORK/tree" > "$WORK/out" 2> "$WORK/err"
    RC=$?
    OUT=$(cat "$WORK/out"); ERR=$(cat "$WORK/err")
}
_stat() { printf '%s\n' "$OUT" | grep '^STAT' | tail -1 | sed -n "s/.*[[:space:]]$1=\([0-9]*\).*/\1/p"; }
_sites() { _stat unallowed_sites; }

# The trap/return words in the fixture bodies below are assembled from pieces
# so THIS suite — itself in the lint's population — never carries the flagged
# shape in its own code. Heredoc bodies and single-quoted strings are invisible
# to the lint (stripped / masked), so these are belt and braces, not the
# mechanism; the mechanism is stated in the lint header.
T='tr''ap'
R='ret''urn'

echo '=== POSITIVE: the walk reaches a bare return through a WORD handler and a callee ==='
_mktree
_plant a.sh \
    "_is_mine() {" \
    "    [[ \"\${1:-}\" == ours ]]" \
    "    $R" \
    "}" \
    "on_sig() {" \
    "    _is_mine || $R 1" \
    "    rm -f marker" \
    "}" \
    "$T on_sig TERM"
_run
assert_eq "P1 a bare return two hops below a word-form trap handler exits 1"   "$RC" "1"
assert_eq "P1 …exactly one unallowed site"                                       "$(_sites)" "1"
assert_contains "P1 …naming the function at its line" "$OUT" $'monitor/a.sh:4\t_is_mine\t'
assert_contains "P1 …with the chain from the trap" "$OUT" 'trap@monitor/a.sh:10 -> on_sig() -> _is_mine()'

echo '=== POSITIVE: an INLINE handler string names the callee ==='
_mktree
_plant a.sh \
    "_cleanup() {" \
    "    [[ -f x ]] && $R" \
    "    rm -f x" \
    "}" \
    "$T '_cleanup; exit 130' INT"
_run
assert_eq "P2 a callee named inside a quoted handler string is reached"  "$(_sites)" "1"
assert_contains "P2 …naming it"                                         "$OUT" $'\t_cleanup\t'

echo '=== POSITIVE: every bare spelling is a site; explicit forms beside them are not ==='
_mktree
_plant a.sh \
    "s1() { [[ -e a ]]; $R; }" \
    "s2() {" \
    "    [[ -e a ]]" \
    "    $R" \
    "}" \
    "s3() { [[ -e a ]] && $R; :; }" \
    "s4() { [[ -e a ]] || $R; :; }" \
    "s5() { if [[ -e a ]]; then $R; fi; :; }" \
    "s6() { { :; $R; } ; :; }" \
    "e1() { [[ -e a ]]; $R 0; }" \
    "e2() { [[ -e a ]]; $R 1; }" \
    "e3() { [[ -e a ]]; $R \$?; }" \
    "e4() { local rc=\$?; $R \"\$rc\"; }" \
    "e5() { local rc=\$?; $R \$rc; }" \
    "h() { s1; s2; s3; s4; s5; s6; e1; e2; e3; e4; e5; }" \
    "$T h EXIT"
_run
assert_eq "P3 six bare spellings (bare, EOL, &&, ||, then, one-liner group) are six sites" "$(_sites)" "6"
assert_contains "P3 …the one-liner group form is among them"                                  "$OUT" $'\ts6\t'
assert_eq "N1 …and none of the five EXPLICIT forms (0, 1, \$?, \"\$rc\", \$rc) is a site"    "$(printf '%s\n' "$OUT" | grep -cE $'\te[1-5]\t')" "0"

echo '=== POSITIVE: the chain crosses a `source` into another file ==='
_mktree
_plant lib.sh \
    "lib_helper() {" \
    "    [[ -e f ]]" \
    "    $R" \
    "}"
_plant a.sh \
    ". \"\$(dirname \"\${BASH_SOURCE[0]}\")/lib.sh\"" \
    "cleanup() { lib_helper; }" \
    "$T cleanup EXIT"
_run
assert_eq "P4 a callee defined in a SOURCED file is reached"          "$(_sites)" "1"
assert_contains "P4 …and the chain marks the cross-file hop"          "$OUT" 'cleanup() -> lib_helper()@monitor/lib.sh'

echo '=== POSITIVE: th_trap_exit — this tree'"'"'s trap-appending wrapper — is a trap site ==='
_mktree
_plant a.sh \
    "teardown() { [[ -d d ]]; $R; }" \
    "th_$T""_exit teardown"
_run
assert_eq "P5 a handler handed to th_trap_exit is walked like a trap's" "$(_sites)" "1"

echo '=== MUTATION: the REAL file, with its fixed line put back ==='
# The measured defect lived in cc-restart-watchdog-loop.sh:_marker_is_mine; the
# fix was an explicit `return 1` at the end of the function. Copy the real file
# into the fixture, revert exactly that line to a bare `return`, and the lint
# must redden naming the function AND the TERM-trap chain it is reached by.
_mktree
cp "$REPO_ROOT/monitor/cc-restart-watchdog-loop.sh" "$WORK/tree/monitor/cc-restart-watchdog-loop.sh"
_run
assert_eq "M0 control: the real file UNMUTATED yields no site"                 "$(_sites)" "0"
awk -v R="$R" '
    /^_marker_is_mine\(\)/ { inside = 1 }
    inside && /^}/           { inside = 0 }
    inside && /^    return 1$/ { last = NR }
    { L[NR] = $0 }
    END { for (i = 1; i <= NR; i++) print (i == last ? "    " R : L[i]) }
' "$REPO_ROOT/monitor/cc-restart-watchdog-loop.sh" > "$WORK/tree/monitor/cc-restart-watchdog-loop.sh"
assert_eq "M1 the mutation APPLIED (one line differs from the real file)" \
    "$(diff "$REPO_ROOT/monitor/cc-restart-watchdog-loop.sh" "$WORK/tree/monitor/cc-restart-watchdog-loop.sh" | grep -c '^[<>]')" "2"
_run
assert_eq "M2 the re-inserted bare return reddens the lint"                     "$RC" "1"
assert_contains "M3 …naming _marker_is_mine by its TERM-trap chain" "$OUT" \
    '_on_signal() -> _release_marker_if_mine() -> _marker_is_mine()'

echo '=== NEGATIVE: the near-misses that share the silhouette are not sites ==='
_mktree
_plant a.sh \
    "unreached() { [[ -e a ]]; $R; }" \
    "h() { :; }" \
    "$T h EXIT"
_run
assert_eq "N2 a bare return in a function NO handler reaches is not a site" "$(_sites)" "0"

_mktree
_plant a.sh \
    "h() {" \
    "    echo \"$R\"" \
    "    printf '%s\\n' 'x; $R; }'" \
    "    awk '{" \
    "        if (x) $R" \
    "    }' /dev/null" \
    "}" \
    "$T h EXIT"
_run
assert_eq "N3 the word return inside a string, or inside a multi-line quoted awk program, is not code" "$(_sites)" "0"

_mktree
_plant a.sh \
    "cleanup() { [[ -e a ]]; $R; }" \
    "# $T cleanup EXIT   (a comment, not a trap)"
_run
assert_eq "N4 a COMMENT naming the trap installs nothing — no sites"  "$(_sites)" "0"
assert_eq "N4 …and no trap is counted"                                 "$(_stat traps)" "0"

_mktree
_plant a.sh \
    "cleanup() { [[ -e a ]]; $R; }" \
    "$T - EXIT" \
    "$T '' INT" \
    "$T -p"
_run
assert_eq "N5 the reset / ignore / print forms install no handler"    "$(_stat traps)" "0"

_mktree
_plant a.sh \
    "cleanup() { :; }" \
    "cleanup_all() { [[ -e a ]]; $R; }" \
    "$T cleanup EXIT"
_run
assert_eq "N6 a function whose name merely CONTAINS the handler's is not reached" "$(_sites)" "0"

# The two faces of the TEXT predicate, pinned side by side so neither is
# mistaken for the other. A name that appears as a LITERAL anywhere on a code
# line of the body is an edge — even as an assignment's value — which is the
# stated OVER-count, and it happens to cover the commonest dynamic-call shape.
# A name that arrives from OUTSIDE the body (read from a file, passed in) is
# invisible to the walk — the stated UNDER-count. Pinned so both stay deliberate.
_mktree
_plant a.sh \
    "helper() { [[ -e a ]]; $R; }" \
    "h() { local fn=helper; \"\$fn\"; }" \
    "$T h EXIT"
_run
assert_eq "N7a a name assigned as a LITERAL in the body is an edge even when called through the variable (the over-count, covering this shape)" "$(_sites)" "1"
_mktree
_plant a.sh \
    "helper() { [[ -e a ]]; $R; }" \
    "h() { local fn; fn=\$(cat which.txt); \"\$fn\"; }" \
    "$T h EXIT"
_run
assert_eq "N7b a call through a VARIABLE whose value is not in the body is NOT followed (the stated under-count, pinned so it is deliberate)" "$(_sites)" "0"

_mktree
_plant a.sh \
    "helper() { [[ -e a ]]; $R; }" \
    "hnd='helper'" \
    "$T \"\$hnd\" EXIT"
_run
assert_eq "N8 a handler that is a VARIABLE is counted dynamic and reaches nothing" "$(_stat dynamic_traps)" "1"

echo '=== ALLOWLIST: a row exempts its site; a stale row reddens; a bare row refuses ==='
_mktree
_plant a.sh \
    "_is_mine() { [[ -e a ]]; $R; }" \
    "on_sig() { _is_mine || $R 1; }" \
    "$T on_sig TERM"
ALLOW="$WORK/allow"
printf 'monitor/a.sh\t_is_mine\tthe handler ignores the status: adjudicated benign for this fixture\n' > "$ALLOW"
_run
assert_eq "A1 an allowlisted site does not redden"                    "$RC" "0"
assert_contains "A1 …and is printed as ALLOWED with its reason"        "$OUT" $'ALLOWED\tmonitor/a.sh:2\t_is_mine\t'
assert_eq "A1 …unallowed count is 0"                                   "$(_sites)" "0"
printf 'monitor/a.sh\t_is_mine\tstill benign\nmonitor/a.sh\tgone_fn\tfixed long ago\n' > "$ALLOW"
_run
assert_eq "A2 a STALE row (no reachable bare return there) reddens"    "$RC" "1"
assert_contains "A2 …naming the row"                                   "$OUT" $'STALE-ALLOWLIST\tmonitor/a.sh\tgone_fn'
printf 'monitor/a.sh\t_is_mine\n' > "$ALLOW"
_run
assert_eq "A3 a row WITHOUT a reason is REFUSED (3), never a pass"     "$RC" "3"
unset ALLOW

echo '=== REFUSAL: a population it cannot build or read is not one it can certify ==='
rm -rf "$WORK/notrepo"; mkdir -p "$WORK/notrepo/monitor/watcher"
cp "$REPO_ROOT/monitor/shell-files.sh" "$WORK/notrepo/monitor/"
cp "$REPO_ROOT/monitor/watcher/_shell_quotes.awk" "$WORK/notrepo/monitor/watcher/"
bash "$LINT" --allowlist "$NOALLOW" "$WORK/notrepo" > "$WORK/out" 2> "$WORK/err"; _rc=$?
assert_eq "R1 a directory that is not a repository (no tracked files) is REFUSED (3)" "$_rc" "3"
assert_contains "R1 …and it says the population is EMPTY" "$(cat "$WORK/err")" "EMPTY"
_mktree
_plant a.sh "h() { [[ -e a ]]; $R; }" "$T h EXIT"
rm -f "$WORK/tree/monitor/watcher/_shell_quotes.awk"
_run
assert_eq "R2 a missing stripper dependency is REFUSED (3), never reported clean" "$RC" "3"

echo '=== REAL TREE: clean, non-vacuous, and the walk still reaches the measured site ==='
bash "$LINT" "$REPO_ROOT" > "$WORK/real.out" 2> "$WORK/real.err"; _rc=$?
assert_eq "T1 no tracked shell file holds a bare return reachable from a trap (exit 0)" "$_rc" "0"
_n_reach=$(grep '^STAT' "$WORK/real.out" | tail -1 | sed -n 's/.*reachable_functions=\([0-9]*\).*/\1/p')
assert_eq "T2 the walk reaches a non-trivial set on the real tree (>= 50; got ${_n_reach:-?})" \
    "$(( ${_n_reach:-0} >= 50 ? 1 : 0 ))" "1"
_reach=$(bash "$LINT" --reachable "$REPO_ROOT" 2>/dev/null)
assert_contains "T3 POTENCY: _marker_is_mine — where the defect was measured — is still reached by its TERM-trap chain" \
    "$_reach" $'monitor/cc-restart-watchdog-loop.sh\t_marker_is_mine\ttrap@monitor/cc-restart-watchdog-loop.sh:'
_pop=$(bash "$LINT" --files "$REPO_ROOT")
_n_pop=$(printf '%s\n' "$_pop" | grep -c .)
assert_eq "T4 the population clears a broken-enumerator floor (>= 300; got $_n_pop)" "$(( _n_pop >= 300 ? 1 : 0 ))" "1"
assert_contains "T5 the extensionless dispatcher (monitor/ng) is in the population — a *.sh glob would miss it" "$_pop" "monitor/ng"
assert_contains "T6 a sourced dotfile with neither extension nor shebang (monitor/shellenv/.zshenv) is in" "$_pop" "monitor/shellenv/.zshenv"

# ---- assertion-count guard (count=exact, summary-honesty) -------------------
# The ledger certifies that SOMETHING was asserted and no FAIL was lost to a
# subshell; only an exact count makes a VANISHED assertion redden.
EXPECTED_ASSERTIONS=40
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} ))
# ONE physical line, deliberately: the summary-honesty classifier reads
# `count=exact` off the `assert_eq` prefix and the EXPECTED operand on the SAME
# line, so a `\`-split guard silently classifies `count=none` (its recorded
# non-kill). Mutation-tested at birth: deleting this line reddens that guard.
assert_eq "assertion TOTAL matches EXPECTED_ASSERTIONS — no assertion silently dropped or added" "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
