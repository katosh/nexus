#!/usr/bin/env bash
# test-requests-dir.sh — the request inbox has ONE location resolver, and every
# reader and writer uses it (your-org/nexus-code#1723).
#
#   A. the resolver's precedence: NEXUS_REQUESTS_DIR, then monitor.requests.dir
#      (only for the state dir the config describes), then <state>/requests;
#      a relative value is REFUSED; a missing configured dir or a dangling
#      symlink is LOUD for readers, a missing default dir is not.
#   B. end to end: with the inbox configured, `request-channel.sh file` lands
#      the request THERE, `list` sees it, the watcher's _requests_dir and the
#      skeptic channel resolve the same place, and `list` on a missing
#      configured inbox refuses (rc 7) instead of a silent empty answer.
#   C. a population lint: no tracked monitor/ shell file outside the resolver
#      composes `<state-var>/requests`, so a new reader cannot split the inbox.
#
# Run: bash monitor/watcher/test-requests-dir.sh

set -uo pipefail
if [[ -z "${_REQDIR_TEST_REEXEC:-}" ]]; then
    export _REQDIR_TEST_REEXEC=1
    # Never read the operator's live config or state (your-org/nexus-code#833).
    exec env -u NEXUS_ROOT -u NEXUS_STATE_DIR -u NEXUS_REQUESTS_DIR \
        bash "${BASH_SOURCE[0]}" "$@"
fi

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON=$(cd "$_dir/.." && pwd)
REPO=$(cd "$MON/.." && pwd)

# The lint's corpus (section C): every tracked monitor/ file with a shell
# shebang, minus the suites, the helper library and the resolver itself. ONE
# enumerator, called by section C and by gp_population below.
_rd_corpus() {   # -> repo-relative paths
    local f head
    (cd "$REPO" && git ls-files -- ':(glob)monitor/**') | while IFS= read -r f; do
        case "$f" in */test-*|*/_test_helpers.sh|monitor/_requests_dir.sh) continue ;; esac
        [[ -f "$REPO/$f" ]] || continue
        # CAPTURE, THEN MATCH (no early-exit reader on a pipe, #622). Match
        # the FIRST LINE only: bash's `.` crosses newlines, so matching the
        # whole 200-byte head admitted a python script whose docstring says
        # "subshell".
        head=$(head -c 200 "$REPO/$f" 2>/dev/null)
        head=${head%%$'\n'*}
        [[ "$head" =~ ^\#\!.*(ba)?sh ]] && printf '%s\n' "$f"
    done
}

# --- the guard's population (your-org/nexus-code#1747's lesson) -------------
# Section C lints every tracked monitor/ shell file, so an edit anywhere can
# redden it: it must be SELECTABLE by guards-for-diff. Its population is the
# corpus enumerator above (called, not copied), plus the resolver, the two
# channel scripts sections A-B drive, the watcher module B5 sources, and the
# helper library. Placed before anything prints: gp_handle exits on the flag.
. "$MON/_guard_population.sh"
gp_population() {
    _rd_corpus | sed "s|^|$REPO/|"
    printf '%s\n' "$MON/_requests_dir.sh" "$_dir/_test_helpers.sh"
}
gp_handle "$@"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A fixture nexus whose config/load.sh answers from a key=value file, so the
# resolver's config leg is exercised without the operator's nexus.yml.
FROOT="$WORK/nexus"
mkdir -p "$FROOT/config" "$FROOT/monitor/.state"
cat > "$FROOT/config/load.sh" <<'EOF'
#!/usr/bin/env bash
f="$(dirname "${BASH_SOURCE[0]}")/kv"
[[ -f "$f" ]] && awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$f"
exit 0
EOF
chmod +x "$FROOT/config/load.sh"
printf 'nexus.root=%s\n' "$FROOT" > "$FROOT/config/kv"

lib() { ( . "$MON/_requests_dir.sh"; "$@" ); }

echo '=== A. resolver precedence ==='
assert_eq "A1 default: <state>/requests" \
    "$(NEXUS_ROOT="$FROOT" lib nexus_requests_dir "$FROOT/monitor/.state")" "$FROOT/monitor/.state/requests"
assert_eq "A1 default source" \
    "$(NEXUS_ROOT="$FROOT" lib nexus_requests_dir_source "$FROOT/monitor/.state")" "default"

printf 'monitor.requests.dir=%s\n' "$WORK/inbox-cfg" >> "$FROOT/config/kv"
assert_eq "A2 config key honoured for the state dir the config describes" \
    "$(NEXUS_ROOT="$FROOT" lib nexus_requests_dir "$FROOT/monitor/.state")" "$WORK/inbox-cfg"
assert_eq "A2 config source" \
    "$(NEXUS_ROOT="$FROOT" lib nexus_requests_dir_source "$FROOT/monitor/.state")" "config"
mkdir -p "$WORK/fixture-state"
assert_eq "A3 config key IGNORED for any other state dir (a fixture never reaches the live inbox)" \
    "$(NEXUS_ROOT="$FROOT" lib nexus_requests_dir "$WORK/fixture-state")" "$WORK/fixture-state/requests"
assert_eq "A4 NEXUS_REQUESTS_DIR wins over the config key" \
    "$(NEXUS_ROOT="$FROOT" NEXUS_REQUESTS_DIR="$WORK/inbox-env" lib nexus_requests_dir "$FROOT/monitor/.state")" "$WORK/inbox-env"
assert_eq "A5 a ~/ value is expanded" \
    "$(HOME="$WORK/h" NEXUS_REQUESTS_DIR='~/rq' lib nexus_requests_dir "$WORK/fixture-state")" "$WORK/h/rq"
out=$(NEXUS_REQUESTS_DIR=rel/dir lib nexus_requests_dir "$WORK/fixture-state" 2>"$WORK/a6.err"); rc=$?
assert_eq "A6 a RELATIVE value is refused (rc 2), never replaced by the default" "$rc" "2"
assert_empty "A6 …and prints no path" "$out"
assert_contains "A6 …and says why" "$(cat "$WORK/a6.err")" "absolute"

lib nexus_requests_dir_check "$WORK/nope" default; rc=$?
assert_eq "A7 a missing DEFAULT inbox is a fresh nexus: rc 0" "$rc" "0"
lib nexus_requests_dir_check "$WORK/nope" config 2>"$WORK/a8.err"; rc=$?
assert_eq "A8 a missing CONFIGURED inbox is LOUD: rc 3" "$rc" "3"
assert_contains "A8 …naming the setting" "$(cat "$WORK/a8.err")" "monitor.requests.dir"
ln -s "$WORK/gone" "$WORK/dangling"
lib nexus_requests_dir_check "$WORK/dangling" default 2>/dev/null; rc=$?
assert_eq "A9 a dangling symlink is LOUD even as the default: rc 3" "$rc" "3"

echo '=== B. end to end through request-channel.sh ==='
export NEXUS_STATE_DIR="$WORK/state-b"; mkdir -p "$NEXUS_STATE_DIR"
export NEXUS_REQUESTS_DIR="$WORK/inbox-b"
id=$("$MON/request-channel.sh" file --origin w-b --kind question --slug where \
        --message "which inbox?" 2>"$WORK/b.err"); rc=$?
assert_eq "B1 file succeeds with a configured inbox" "$rc" "0"
assert_eq "B1 the request lands in the CONFIGURED inbox" "$([[ -f "$WORK/inbox-b/$id.new.md" ]] && echo yes)" "yes"
assert_eq "B1 …and NOT under <state>/requests" "$([[ -e "$NEXUS_STATE_DIR/requests" ]] && echo split || echo none)" "none"
assert_eq "B2 a configured inbox is created private (0700)" "$(stat -c %a "$WORK/inbox-b" 2>/dev/null)" "700"
assert_contains "B3 list sees it" "$("$MON/request-channel.sh" list 2>&1)" "$id"
assert_eq "B4 request-channel dir agrees" "$("$MON/request-channel.sh" dir)" "$WORK/inbox-b"
got=$( STATE_DIR="$NEXUS_STATE_DIR"; source "$_dir/_requests.sh" >/dev/null 2>&1; _requests_dir )
assert_eq "B5 the watcher's _requests_dir resolves the same inbox" "$got" "$WORK/inbox-b"
left=$(ls -A "$WORK/inbox-b" | grep -c '^\.chan\.' )
assert_eq "B6 no publish temp left behind (every mv stays inside the inbox)" "$left" "0"

export NEXUS_REQUESTS_DIR="$WORK/inbox-missing"
out=$("$MON/request-channel.sh" list 2>"$WORK/b7.err"); rc=$?
assert_eq "B7 list on a MISSING configured inbox refuses: rc 7 (was a silent empty rc 0)" "$rc" "7"
assert_empty "B7 …with no rows" "$out"
assert_contains "B7 …and says why on stderr" "$(cat "$WORK/b7.err")" "does not exist"
unset NEXUS_REQUESTS_DIR NEXUS_STATE_DIR

echo '=== C. population lint: one composer of the inbox path ==='
# A `<var naming a state dir>/requests` composition anywhere but the resolver
# would split the inbox the day the key is set. Comment lines are ignored.
# Bracket expressions, never backslashes: `awk -v` processes escapes, and the
# first draft's `\$\{` arrived as `${` — a lint that flagged nothing, caught by
# C2 below.
_compose_re='[$][{]?[A-Za-z_]*[Ss][Tt][Aa][Tt][Ee][A-Za-z_]*[}]?"?/requests([^A-Za-z0-9_.-]|$)'
lint() {   # <file>... -> offending "<file>:<line>: <text>" rows
    local f
    for f in "$@"; do
        awk -v f="$f" -v re="$_compose_re" '
            /^[[:space:]]*#/ { next }
            $0 ~ re { printf "%s:%d: %s\n", f, NR, $0 }' "$f"
    done
}
mapfile -t corpus < <(_rd_corpus)
(( ${#corpus[@]} > 100 )) && corpus_ok=yes || corpus_ok="no (${#corpus[@]})"
assert_eq "C0 the corpus is the real shell tree (>100 files), not a silent zero" "$corpus_ok" "yes"
hits=$(cd "$REPO" && lint "${corpus[@]}")
assert_empty "C1 no tracked monitor/ shell file composes <state>/requests outside the resolver" "$hits"
printf '#!/usr/bin/env bash\nrq="$STATE_DIR/requests"\n# rq="$STATE_DIR/requests" (comment)\n' > "$WORK/plant.sh"
assert_contains "C2 positive control: a planted composition IS flagged" "$(lint "$WORK/plant.sh")" 'plant.sh:2:'
assert_not_contains "C2 …and its commented twin is not" "$(lint "$WORK/plant.sh")" 'plant.sh:3:'

# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, count=exact): a
# dropped or added assertion is a FAIL, never a quieter green.
#   A 14 (A1 2, A2 2, A3-A5 3, A6 3, A7 1, A8 2, A9 1) | B 11 (B1 3, B2-B6 5, B7 3) | C 4
EXPECTED=$(( 14 + 11 + 4 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
