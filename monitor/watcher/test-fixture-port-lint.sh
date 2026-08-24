#!/usr/bin/env bash
# A FIXTURE PORT IS ALLOCATED BY BIND PROBE, NEVER BY ARITHMETIC.
# (your-org/nexus-code#800, the class established by #769)
#
# WHY THIS FILE EXISTS. `#769` established that a port allocator probing with a
# TCP **connect** predicts a property it does not measure: a connect sees only a
# LISTENING socket, so a port held as the EPHEMERAL SOURCE PORT of an outbound
# connection answers "free" and then fails `bind()` with `[Errno 98] Address
# already in use` — `SO_REUSEADDR` or not. `#797` fixed the one allocator.
# `#800` is the same class arriving in a WEAKER form: suites that derive fixture
# ports with bare arithmetic — `PORT=$(( 21000 + ($$ % 4000) ))` — do not
# mispredict bindability, they never ask.
#
# WHY IT MATTERS MORE THAN A FLAKE. A seized port makes the fixture fail to
# start, its case SKIPS, and the suite still prints ALL TESTS PASSED (66/0
# instead of 78/0 has been observed). The decisive case silently stops running,
# which is your-org/nexus-code#805's defect wearing a network costume.
#
# ── WHAT THIS LINT LEARNED FROM MEASURING, AND THE ISSUE DID NOT ──────────
#
# `#800` proposed migrating "test-remote-service.sh and any other suite deriving
# ports arithmetically". Measured against the tree, that would have been WRONG
# for three of the four files a naive grep returns, because deriving a NUMBER
# arithmetically is not the defect — BINDING an unprobed number is:
#
#   * test-jupyter-service.sh / test-labsh-phantom-adopt.sh derive
#     `LABSH_STUB_BASE_PORT` as the START of a scan, and the stub they write
#     then finds the first port in [base, base+40) that `bind()` accepts. The
#     bind probe is already there; the arithmetic only picks where to start.
#   * test-service-health.sh's `JPORT` is written into a fixture env file and
#     passed as an argv token to a FAKE process (a copied `bash` spinning in a
#     loop). Nothing ever binds it. A port nobody binds cannot be seized.
#
# So the true population of the defect was ONE file — with ELEVEN call sites,
# not the two the issue names, including two window bases used TWICE each
# (26000 and 27000), which handed two fixtures the same port off one `$$`.
#
# That asymmetry is the whole design of this lint: it flags an arithmetic
# derivation only when the same file also BINDS, and it exempts by MARKER with
# a stated reason — never by filename. A filename allowlist erodes silently,
# and applied to a scanner's own file it blinds the one file best able to hide
# a violation.
#
# Run: bash monitor/watcher/test-fixture-port-lint.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

# ── THE MARKER ──────────────────────────────────────────────────────────
# A line may derive a port arithmetically if it carries the marker — either on
# the derivation line itself, or in the comment block directly above it:
#
#     fixture-port-lint: <token>  <reason>
#
# The token names WHICH argument is being made; the reason is prose a reviewer
# reads. Same shape as the `ambient-shell-option-scope:` marker already used in
# _test_helpers.sh. Recognised tokens:
#
#   allow-scan-base   the number is the START of a bind-probing scan, not a
#                     port anything binds directly
#   allow-never-bound the number is only ever passed as data/argv; no process
#                     in this suite binds it
MARKER_RE='fixture-port-lint:[[:space:]]*(allow-scan-base|allow-never-bound)[[:space:]]+[^[:space:]]'

# ── THE DETECTOR ────────────────────────────────────────────────────────
# Emit `HIT:<file>:<line>` for each arithmetic port derivation that carries no
# reasoned marker, and `STALE:<file>:<line>` for each marker that no longer
# guards one.
#
# THE MARKER MAY SIT ON THE DERIVATION LINE OR IN THE COMMENT BLOCK DIRECTLY
# ABOVE IT. That is not a convenience — it is the convention this repo already
# uses (`ambient-shell-option-scope: allow-unconditional-unset` sits in the
# comment block above its `shopt -u` in _test_helpers.sh), and reasons worth
# reading do not fit on the end of a line of code. The first draft of this lint
# accepted only the same-line form and promptly flagged all three legitimately
# marked call sites; it is recorded here because a marker convention nobody can
# satisfy is how a guard earns a blanket exemption and stops guarding.
#
# Reads the heredoc-stripped source view (your-org/nexus-code#806), so fixture
# text a suite WRITES is never mistaken for code it RUNS — including this
# file's own plants below.
scan_ports() {
    local f="$1" src="${2:-}"
    [[ -n "$src" ]] || src=$(th_strip_heredocs "$f" 2>/dev/null) || return 0
    printf '%s\n' "$src" | awk -v file="${f#"$REPO_ROOT"/}" -v mre="$MARKER_RE" '
        function is_deriv(l) { return l ~ /[A-Za-z_]*(PORT|port)[A-Za-z_]*=\$\(\(/ }
        function is_comment(l) { sub(/^[ \t]+/, "", l); return substr(l, 1, 1) == "#" }
        function is_blank(l) { return l ~ /^[ \t]*$/ }
        {
            if (is_blank($0)) { marked = 0; mline = 0; next }
            if (is_comment($0)) {
                if ($0 ~ mre) { marked = 1; mline = NR }
                next
            }
            # a code line
            if (is_deriv($0)) {
                if (!marked && $0 !~ mre) printf("HIT:%s:%d\n", file, NR)
            } else if (marked) {
                printf("STALE:%s:%d\n", file, mline)
            }
            marked = 0; mline = 0
        }
        END { if (marked) printf("STALE:%s:%d\n", file, mline) }
    '
}

# ── POSITIVE CONTROL, FIRST ─────────────────────────────────────────────
# A scan that finds nothing is indistinguishable from a scan that CANNOT find
# anything. Prove the detector fires before trusting its zero.
PLANT=$(mktemp -d) || { echo "FAIL: mktemp for the plant"; exit 1; }
trap 'rm -rf "$PLANT"' EXIT

cat >"$PLANT/test-planted-port.sh" <<'PLANTED'
#!/usr/bin/env bash
FBPORT=$(( 30000 + ($$ % 4000) ))
python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', $FBPORT))"
PLANTED
assert_eq "POSITIVE CONTROL: an unmarked arithmetic port derivation is flagged" \
    "$(scan_ports "$PLANT/test-planted-port.sh" | wc -l)" "1"

cat >"$PLANT/test-planted-marked.sh" <<'PLANTED'
#!/usr/bin/env bash
# fixture-port-lint: allow-scan-base  the stub bind-probes [base, base+40)
BASE_PORT=$(( 20000 + ($$ % 8000) ))
PLANTED
assert_eq "NEGATIVE CONTROL: a MARKED derivation with a reason is not flagged" \
    "$(scan_ports "$PLANT/test-planted-marked.sh" | wc -l)" "0"

cat >"$PLANT/test-planted-alloc.sh" <<'PLANTED'
#!/usr/bin/env bash
PORT=$(th_alloc_port 21000) || th_abort "no bindable fixture port"
PLANTED
assert_eq "NEGATIVE CONTROL: the th_alloc_port remedy is not itself flagged" \
    "$(scan_ports "$PLANT/test-planted-alloc.sh" | wc -l)" "0"

# THE HEREDOC CONTROL (your-org/nexus-code#806). This file writes the forbidden
# idiom LITERALLY three times above, inside quoted heredocs. Before the stripped
# view, a source-text lint flagged its own plants the moment its file became
# tracked — `#797` lost five CI bands to exactly that. This asserts the fix from
# the outside: scanning THIS file must return nothing.
assert_eq "the lint does not flag its own planted fixtures (heredoc-aware)" \
    "$(scan_ports "$_test_dir/$(basename "${BASH_SOURCE[0]}")" | wc -l)" "0"

# ── THE CORPUS ──────────────────────────────────────────────────────────
# `git ls-files` with a GLOB pathspec — NOT `git ls-tree`, whose pathspecs are
# path prefixes and which returns a confident zero for this query
# (your-org/nexus-code#770). Sanity-checked against a floor below, because a
# silent zero here would make this whole file a check that cannot fail.
cd "$REPO_ROOT" || { echo "FAIL: cd repo root"; exit 1; }
n_files=0
hits=""
stales=""
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    n_files=$(( n_files + 1 ))
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        case "$r" in
            HIT:*)   hits+="${r#HIT:}"$'\n' ;;
            STALE:*) stales+="${r#STALE:}"$'\n' ;;
        esac
    done < <(scan_ports "$f")
done < <(git ls-files -- '*test-*.sh')

if (( n_files >= 200 )); then
    _th_pass
    printf '  PASS: the corpus was actually enumerated (%d test files)\n' "$n_files"
else
    printf '  FAIL: enumeration returned %d files (expected >=200) — the scan is blind\n' "$n_files" >&2
    _th_fail
fi

hits=$(printf '%s' "$hits" | grep -v '^$' || true)
if [[ -z "$hits" ]]; then
    _th_pass
    printf '  PASS: no test file derives a bound fixture port arithmetically (%d scanned)\n' "$n_files"
else
    printf '  FAIL: arithmetic fixture-port derivation(s) with no bind probe:\n' >&2
    printf '%s\n' "$hits" | sed 's/^/         /' >&2
    printf '        Use `PORT=$(th_alloc_port <base>) || th_abort "…"`, which probes with\n' >&2
    printf '        bind() and carries a process-wide exclusion set. If the number is a\n' >&2
    printf '        scan base or is never bound, say so on the line or just above it:\n' >&2
    printf '          # fixture-port-lint: allow-scan-base  <why>\n' >&2
    printf '          # fixture-port-lint: allow-never-bound  <why>\n' >&2
    _th_fail
fi

# Exemptions must stay HONEST. A marker whose next code line no longer derives a
# port is stale, and stale exemptions are how an allowlist rots into a rubber
# stamp — the same reason the sibling manifest lints check their own MANIFEST.
stales=$(printf '%s' "$stales" | grep -v '^$' || true)
if [[ -z "$stales" ]]; then
    _th_pass
    echo "  PASS: no stale fixture-port exemptions"
else
    printf '  FAIL: fixture-port marker(s) that no longer guard a port derivation:\n' >&2
    printf '%s\n' "$stales" | sed 's/^/         /' >&2
    _th_fail
fi

# EXPECTED-COUNT GUARD (your-org/nexus-code#807). An `assert_*` that never runs
# reports zero failures and reads as a pass; the count is what makes that
# silence loud. Pinned, not derived: every assertion above is unconditional.
EXPECTED=7
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
