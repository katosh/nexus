#!/usr/bin/env bash
# stub-claude-fixtures.sh — enumerate the test fixtures that build their own
# `claude` stub, and record the FACTS about how each one pins the resolution.
#
# Run: bash monitor/watcher/stub-claude-fixtures.sh [repo-root]
# Output: one TAB-separated row per fixture, sorted:
#
#     <repo-relative-path>\t<local|path>\t<claude-bin|no-claude-bin>\t<guarded|unguarded>
#
# your-org/nexus-code#764, follow-up to `#746` / PR `#759`.
#
# THE AXIS. `monitor/_claude-bin.sh` resolves in three ordered steps:
#
#   1. `$CLAUDE_BIN` from the environment          — short-circuit
#   2. `$NEXUS_ROOT/node_modules/.bin/claude`      — project-local install
#   3. `command -v claude`                         — PATH
#
# The `#746` hazard — `monitor/locals-env.sh` re-fronting `$NEXUS_LOCALS/bin`
# ahead of whatever the caller prepended, reached by EVERY non-interactive bash
# through `BASH_ENV` — can only bite at STEP 3. A fixture that pins step 1 or
# step 2 wins deterministically no matter what PATH says, because both are
# consulted BEFORE PATH. Measured, ambient (hazardous) operator environment:
#
#     stub at $F/node_modules/.bin/claude, NEXUS_ROOT=$F  -> the fixture's stub
#     stub on PATH only                                   -> locals/bin/claude
#
# So this classifier reports which step a fixture's construction lands on. That
# is the axis the MECHANISM varies on. It is deliberately NOT the axis the
# issue's original grep varied on ("creates a file named `claude` and never
# assigns CLAUDE_BIN"), which is a property of the SEARCH: it sorts step-2-immune
# fixtures in with step-3-exposed ones, and 21 of the 22 files it named do not
# have the property it implies.
#
# FACTS, NOT VERDICTS. This script reports what each fixture builds; it does not
# decide whether any fixture is exposed. The disposition — including whether the
# fixture reaches `_claude-bin.sh` at all, which no static scan can settle — lives
# in `stub-claude-fixtures.manifest` alongside a reason, and
# `test-stub-claude-manifest.sh` fails when the two disagree.
#
# COVERAGE BOUNDARY: the population is "a file under `monitor/` that creates an
# executable named exactly `claude`, and is either a `test-*.sh` fixture or shared
# scaffolding inside a `test-integration/` tree". The second clause is not padding
# — `test-integration/_harness.sh` builds the stub for five scenarios and matches
# no `test-*` glob, so a scan written only on the first clause reports a clean
# sweep while the single most consequential member sits outside it. That is how
# the issue's own list came to omit it.
#
# Still off the axis, and NOT claimed about: a stub whose name is held in a
# variable, one unpacked from an archive at runtime, one built by production code
# under `monitor/` that is not test scaffolding, and any fixture outside
# `monitor/`. Reachability of `_claude-bin.sh` is also outside it — no static scan
# can settle that, and it was established here by measurement instead.

set -uo pipefail

# your-org/nexus-code#803 — `--population` prints the file set this scan reads.
# Consumed BEFORE the positional root, because the root is `$1` here and an
# unshifted flag would silently be taken for a directory.
_scf_pop=0
if [[ "${1:-}" == --population ]]; then _scf_pop=1; shift; fi
REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# The operator's interactive `grep` is a ugrep wrapper honouring .gitignore
# (your-org/nexus-code#618). Bind the real binary so this classifier cannot
# return a confident zero.
REAL_GREP=$(command -v grep 2>/dev/null || true)
[[ -x "$REAL_GREP" ]] || REAL_GREP=/bin/grep

# A path component that is exactly `claude` (not `claude-stub.sh`,
# `claude-record.txt`, `claude-code`), as the TARGET of a file-creating verb.
CREATES_CLAUDE='(>[[:space:]]*"?[^"[:space:]]*/claude"?([[:space:]]|$)|(chmod|cp|ln|install|touch)[[:space:]][^;|&]*/claude"?([[:space:]]|$))'
# Same, but specifically the project-local install path (resolver step 2).
CREATES_LOCAL='/node_modules/\.bin/claude'

cd "$REPO_ROOT" || exit 1

# THE SCAN SET, as a function, so `--population` (your-org/nexus-code#803)
# reports the files this classifier actually reads instead of a second copy of
# the enumeration. `guards-for-diff.sh` uses it to tell a worker that its diff
# entered this population before CI does.
_scf_scan_files() {
    {
        # Scenario fixtures, anywhere under monitor/.
        find monitor -name 'test-*.sh' -type f
        # Shared test scaffolding: any shell file inside a test-integration/
        # tree. `_harness.sh` builds the stub `claude` for FIVE scenarios at
        # once and matches no `test-*` glob — the single most consequential
        # member of this population, and the one the issue's grep missed.
        find monitor -path '*/test-integration/*' -name '*.sh' -type f
    } | sort -u
}

# `--population` stops before any classification: the caller asked what this
# scan READS, and the answer includes every file it greps and finds clean —
# which is precisely the file an edit can dirty.
if (( _scf_pop )); then
    _scf_scan_files
    exit 0
fi

while IFS= read -r f; do
    rel="${f#./}"

    "$REAL_GREP" -qE "$CREATES_CLAUDE" "$f" 2>/dev/null || continue

    # Which resolver step does the construction pin? Ask it of the CREATING
    # lines only — a fixture may merely *mention* node_modules elsewhere.
    #
    # CAPTURE, THEN TEST — never `grep … | grep -q` (your-org/nexus-code#1372).
    # Under `set -o pipefail` (line 54) a `-q` reader exits on its FIRST match
    # and closes the pipe; a writer still emitting past the pipe buffer then
    # takes SIGPIPE, the pipeline reports the WRITER's failure, and this `if`
    # falls to its else arm — recording `step=path` for a fixture that IS
    # `step=local`, at rc 0, into a manifest. Forced deterministically with a
    # 20,001-line fixture whose needle is on line 1: OLD -> path, NEW -> local.
    # In production the payload is small so it is racy rather than reliable,
    # which is why it needs a tripwire and not a wait-and-see. The sigpipe lint
    # cannot see this site: both readers are spelled `"$REAL_GREP"`, a variable,
    # and its `_GREPQ_READER` keys on the literal token `grep`.
    creating=$("$REAL_GREP" -hE "$CREATES_CLAUDE" "$f" 2>/dev/null) || creating=""
    # The empty case is decided explicitly (the herestring remedy is documented
    # to invert it at some call sites): no creating line, no local pin.
    if [[ -n "$creating" ]] && "$REAL_GREP" -qE "$CREATES_LOCAL" <<<"$creating"; then
        step=local
    else
        step=path
    fi

    # Does it assign CLAUDE_BIN? The leading class stops `CC_AUTO_CLAUDE_BIN=`
    # and friends from counting as a pin of the resolver's own variable.
    if "$REAL_GREP" -qE '(^|[^A-Za-z0-9_])CLAUDE_BIN=' "$f" 2>/dev/null; then
        pin=claude-bin
    else
        pin=no-claude-bin
    fi

    # Does it assert the resolution?
    if "$REAL_GREP" -q 'th_require_stub_claude' "$f" 2>/dev/null; then
        guard=guarded
    else
        guard=unguarded
    fi

    printf '%s\t%s\t%s\t%s\n' "$rel" "$step" "$pin" "$guard"
done < <(_scf_scan_files) | sort
