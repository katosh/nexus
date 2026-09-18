#!/usr/bin/env bash
# test-errexit-assignment-status.sh — in a shell file that sets `errexit`, the
# shape `out=$(cmd); rc=$?` (one line or two) is a defect: a bare assignment
# whose substitution exits non-zero terminates the shell AT the assignment, so
# `rc=$?` never runs and every arm written to dispatch on `$rc` is unreachable
# for exactly the values it exists to handle (your-org/nexus-code#1403; the
# measured instance made spawn-worker exit 3 AFTER the window was created).
# The safe forms are `rc=0; out=$(cmd) || rc=$?` and `if out=$(cmd); then …`.
#
# Population: every shell file under monitor/ by monitor/shell-files.sh's
# shf_is_shell (a *.sh glob misses monitor/ng), narrowed to files that enable
# errexit — the option is what makes the shape a defect. Declared for
# `ng guards-for-diff`.
# Run: bash monitor/watcher/test-errexit-assignment-status.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
# shellcheck source=monitor/shell-files.sh
. "$REPO_ROOT/monitor/shell-files.sh"

_eas_population() {   # every tracked shell file under monitor/, by predicate
    ( cd "$REPO_ROOT" && git ls-files -- monitor | while IFS= read -r f; do shf_is_shell "$f" && printf '%s\n' "$f"; done; return 0 )
}
# CODE-ONLY TEXT, via shf_strip_comments (comments AND heredoc bodies blanked,
# line numbers preserved): a `set -eu` inside a heredoc'd fixture script is
# not the enclosing file's errexit, and the first cut of this predicate read it
# as one — pulling two non-errexit suites into the population.
_eas_errexit() {   # <file> -> rc 0 iff the file enables errexit in its OWN code
    # herestring, not a pipe into grep -q — the sigpipe lint's own rule (#622)
    grep -qE '^[[:space:]]*set[[:space:]]+(-[a-zA-Z]*e[a-zA-Z]*|-o[[:space:]]+errexit)([[:space:]]|$)' <<<"$(shf_strip_comments "$1" 2>/dev/null)"
}
# The lint over ONE file: `NAME=$( … )` immediately followed (same line after
# `;`, or next non-blank line) by `NAME2=$?`. Comments are skipped.
_eas_lint() {   # <file> -> "file:line: text" per offender
    awk -v F="$1" '
        /^[[:space:]]*#/ { prev = 0; next }
        {
            line = $0
            if (line ~ /^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\$\(.*\);[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\$\?/) { printf "%s:%d: %s\n", F, NR, line; prev = 0; next }
            if (prev && line ~ /^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\$\?[[:space:]]*(#.*)?$/) { printf "%s:%d: %s\n", F, NR, line; prev = 0; next }
            # a bare assignment from a substitution with NO status handling on the line
            if (line ~ /^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\$\(.*\)[[:space:]]*$/ && line !~ /\|\|/) prev = 1; else if (line !~ /^[[:space:]]*$/) prev = 0
        }' <(shf_strip_comments "$1" 2>/dev/null)
}
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { _eas_population; printf '%s\n' monitor/shell-files.sh; }
gp_handle "$@"

WORK=$(mktemp -d -t nxeas-XXXXXX); trap 'rm -rf "$WORK"' EXIT
echo '=== positive control: the lint sees both shapes, and only under errexit does it matter ==='
cat > "$WORK/planted.sh" <<'FIX'
#!/usr/bin/env bash
set -euo pipefail
out=$(cmd 2>&1); rc=$?
res=$(other)
rc2=$?
ok=$(safe) || ok=""
rc3=0; got=$(thing) || rc3=$?
if v=$(gated); then :; fi
# out=$(commented); rc=$?
FIX
hits=$(_eas_lint "$WORK/planted.sh")
assert_eq "planted: the one-line and the two-line shapes are flagged, nothing else" "$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l)" "2"   # one offender per LINE, so lines are the unit
assert_contains "planted: one-line form at :3" "$hits" "planted.sh:3:"
assert_contains "planted: two-line form at :5" "$hits" "planted.sh:5:"
assert_not_contains 'planted: `|| ok=` is not flagged' "$hits" "planted.sh:6:"
assert_not_contains 'planted: `rc=0; …|| rc=$?` is not flagged' "$hits" "planted.sh:7:"
assert_not_contains 'planted: `if v=$(…); then` is not flagged' "$hits" "planted.sh:8:"
assert_eq 'planted: the errexit predicate sees `set -euo pipefail`' "$(_eas_errexit "$WORK/planted.sh" && echo yes || echo no)" "yes"
printf '#!/usr/bin/env bash\nset -uo pipefail\n' > "$WORK/noe.sh"
assert_eq "planted: a file WITHOUT errexit is out of the population" "$(_eas_errexit "$WORK/noe.sh" && echo yes || echo no)" "no"

echo '=== the corpus: errexit files under monitor/ ==='
n_all=0 n_e=0 all=""
while IFS= read -r f; do
    [[ -n "$f" && -f "$REPO_ROOT/$f" ]] || continue
    # this suite's own planted fixture is a heredoc in this file; excluded from
    # the corpus like every lint that carries its positive control inline
    [[ "$f" == monitor/watcher/test-errexit-assignment-status.sh ]] && continue
    n_all=$((n_all+1))
    _eas_errexit "$REPO_ROOT/$f" || continue
    n_e=$((n_e+1))
    h=$(cd "$REPO_ROOT" && _eas_lint "$f"); [[ -n "$h" ]] && all+="$h"$'\n'
done < <(_eas_population)
assert_eq "population is non-vacuous (>= 400 shell files)" "$(( n_all >= 400 ))" "1"
assert_eq "…and the errexit subset is non-empty" "$(( n_e >= 1 ))" "1"
# test-lint-errexit-branch.sh's :87 is a DIFFERENTIAL FIXTURE for the workflow
# lint's EB rule (a deliberately planted specimen under a heading that says so),
# not a live site; it is the one recorded exemption, and it is asserted to
# still EXIST so the exemption cannot outlive its subject.
assert_eq "the one exemption still names a real line" "$(grep -qF 'out=$(echo captured; exit 7); rc=$?' "$REPO_ROOT/monitor/test-lint-errexit-branch.sh" && echo present || echo absent)" "present"
all=$(grep -v '^monitor/test-lint-errexit-branch.sh:' <<<"$all" || true)
assert_eq "#1403 no errexit file carries the shape${all:+ — offenders:
$all}" "$(printf '%s' "$all" | grep -c . || true)" "0"
echo
EXPECTED=12
if (( PASS + FAIL != EXPECTED )); then printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail; fi
th_summary_and_exit
