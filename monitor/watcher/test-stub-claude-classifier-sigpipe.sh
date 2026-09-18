#!/usr/bin/env bash
# test-stub-claude-classifier-sigpipe.sh — the classifier's step decision must
# not depend on the pipe buffer (your-org/nexus-code#1372).
#
# THE DEFECT. `stub-claude-fixtures.sh` decided `step=local` with
#
#     "$REAL_GREP" -hE "$CREATES_CLAUDE" "$f" | "$REAL_GREP" -qE "$CREATES_LOCAL"
#
# under `set -o pipefail`. A `-q` reader exits on its FIRST match and closes the
# pipe; a writer still emitting past the pipe buffer takes SIGPIPE; pipefail
# reports the WRITER's status; the `if` falls to its else arm and records
# `step=path` for a fixture that IS `step=local` — a well-formed wrong value at
# rc 0, feeding `stub-claude-fixtures.manifest`. In production the payload is
# the creating lines of one file, so it is RACY rather than reliable: it will
# not reproduce on demand, which is why it needs a tripwire and not a wait.
#
# WHY NO LINT SAW IT. `test-sigpipe-assertion-lint.sh`'s `_GREPQ_READER` keys
# on the literal command word `grep`; both readers here are `"$REAL_GREP"`, a
# variable, and the lint's header DECLARES that as out of scope. So this suite
# pins the SITE by execution rather than the shape by spelling.
#
# THE FORCING TECHNIQUE is the lint's own: match on line 1, payload far past
# the pipe buffer (64 KiB on Linux). 20,000 further creating lines that do NOT
# match the local needle make the writer emit ~600 KiB after the reader has
# already exited. The pre-fix classifier answers `path` on this fixture every
# time; the capture-then-test form answers `local`. (Fixture: shebang + needle +
# 20,000 bulk lines = 20,002.)
#
# CONTROLS:
#   A — the SAME fixture with the needle line REMOVED must classify `path`, so
#       the assertion measures the needle and not a classifier that says
#       `local` for everything.
#   B — a one-line `local` fixture (no pipe-buffer pressure) classifies `local`
#       under both forms; it is the case that made the defect invisible.
#   C — the planted root is inspected: the fixture really is 20,001 lines, so a
#       fixture that failed to plant cannot pass by being small.
#
# Run: bash monitor/watcher/test-stub-claude-classifier-sigpipe.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
CLASSIFIER="$_test_dir/stub-claude-fixtures.sh"

# NOT a declaring guard (no `--population`), deliberately: the classifier it
# drives is already enrolled through test-stub-claude-manifest.sh, and a
# declaration here needs a guard-populations.manifest row landed in the same
# change — see that manifest before adding one.

WORK=$(mktemp -d -t nexus-scfsp-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

assert_file_exists "the classifier exists" "$CLASSIFIER"

# _plant <root> <with-needle:yes|no> <bulk-lines>
_plant() {
    local root="$1" needle="$2" bulk="$3" f
    mkdir -p "$root/monitor/watcher"
    f="$root/monitor/watcher/test-planted.sh"
    {
        printf '#!/usr/bin/env bash\n'
        [[ "$needle" == yes ]] && printf '%s\n' 'cp stub "$F/node_modules/.bin/claude"'
        # Every bulk line is a CREATING line (matches CREATES_CLAUDE) that does
        # NOT match CREATES_LOCAL — so the writer keeps emitting after the
        # reader's first match, which is the SIGPIPE precondition.
        (( bulk > 0 )) && yes 'cp stub "$F/bin/claude"' | head -n "$bulk"
    } > "$f"
    printf '%s' "$f"
}

_classify() {   # <root> -> the step column for the planted fixture
    bash "$CLASSIFIER" "$1" 2>/dev/null | awk -F'\t' '$1=="monitor/watcher/test-planted.sh"{print $2}'
}

echo '=== THE SITE: needle on line 1, 20,000 creating lines behind it ==='
f=$(_plant "$WORK/big" yes 20000)
assert_eq "control C: the fixture is 20,002 lines — shebang, needle, 20,000 bulk (plant succeeded)" "$(wc -l < "$f")" "20002"
assert_eq "…and is larger than the pipe buffer (> 65536 bytes)" \
          "$( [[ $(wc -c < "$f") -gt 65536 ]] && echo yes || echo no )" "yes"
assert_eq "a step-local fixture with a large payload classifies LOCAL (#1372)" \
          "$(_classify "$WORK/big")" "local"

echo
echo '=== CONTROL A: the same payload WITHOUT the needle classifies path ==='
_plant "$WORK/big-no-needle" no 20000 >/dev/null
assert_eq "no local needle anywhere -> path" "$(_classify "$WORK/big-no-needle")" "path"

echo
echo '=== CONTROL B: a one-line local fixture (no buffer pressure) ==='
_plant "$WORK/small" yes 0 >/dev/null
assert_eq "the small case classifies local under any form — it is what hid the defect" \
          "$(_classify "$WORK/small")" "local"

# ---- assertion-count guard ------------------------------------------------
EXPECTED_ASSERTIONS=6
assert_eq "assertion TOTAL matches the EXPECTED total" "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS"
th_summary_and_exit
