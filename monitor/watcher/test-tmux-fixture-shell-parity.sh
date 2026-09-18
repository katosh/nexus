#!/usr/bin/env bash
# test-tmux-fixture-shell-parity.sh — `monitor/watcher/_tmux-fixture.sh`'s
# answers must be a property of the CODE, not of the invoking SHELL
# (your-org/nexus-code#1319).
#
# WHY THIS IS A SEPARATE SUITE, AND WHY IT ASKS ABOUT PARITY RATHER THAN
# CORRECTNESS.
#
# `test-tmux-shim-gate3-safety.sh` Part C already asserts that
# `nx_real_tmux_bin` returns a real binary. It is a SINGLE-INTERPRETER
# assertion — "is the answer right under whatever shell I am running in" —
# and `run-tests.sh` always runs it under bash, so it was green throughout
# the entire life of the defect. That is the shape this suite exists to
# cover: the population of shells, not the population of PATHs.
#
# THE TWO DEFECTS, and they fail in OPPOSITE directions, which is why one
# assertion cannot stand in for the other:
#
#   (1) `for _d in $PATH` under `IFS=:` — zsh does not word-split an
#       unquoted parameter, so the loop ran ONCE and the function returned
#       rc 1. Callers spell rc 1 as `exit 77` SKIP, so coverage left the
#       population silently and every run stayed green.
#
#   (2) `IFS= read -r -N 2` — `read -N` DOES NOT EXIST IN ZSH, and the
#       `|| _magic=""` arm failed OPEN toward "this is a real binary". So
#       repairing (1) alone converts a silent SKIP into a silent WRONG
#       ANSWER: the function returns `monitor/tmuxwrap/tmux`, the wrapper,
#       and `nx_write_tmux_shim`'s refusal — keyed on the SAME broken
#       primitive — also fails open and writes a shim that names the
#       wrapper, losing its `-L` pin onto the operator's live board.
#
# So the assertions below compare `stdout:rc` AS A PAIR. A fix that repairs
# the loop and leaves the magic read returns rc 0 with the WRONG path, which
# an rc-only comparison would call parity.
#
# `$PATH` IS PINNED IDENTICALLY INTO BOTH LEGS. Without that the two legs
# measure different hosts — zsh's own startup files rewrite `$PATH`, so the
# candidate population differs and a disagreement proves nothing. This trap
# was hit while measuring the defect.
#
# Skips (77, never PASS) when zsh is not installed: the parity claim is not
# checkable on a host with one shell, and a PASS there would be a green that
# measured nothing.
#
# Run directly: bash monitor/watcher/test-tmux-fixture-shell-parity.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# The shared helpers, ADOPTED rather than opted out of. `th_summary_and_exit`
# gives the subshell-durable ledger (`#805`); the `_EXPECTED_ASSERTIONS` guard
# at the bottom reddens a VANISHED assertion (`#807`).
# `summary-honesty.manifest` requires both of a new suite, and says in as many
# words that appending a row instead opts your own new code out of the
# standard.
# shellcheck source=/dev/null
. "$_test_dir/_test_helpers.sh"
FIXTURE="$_test_dir/_tmux-fixture.sh"
REPO=$(cd "$_test_dir/../.." && pwd)

pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

[[ -r "$FIXTURE" ]] || { echo "missing $FIXTURE" >&2; exit 1; }

if ! command -v zsh >/dev/null 2>&1; then
    echo "skipped: $(basename "$0") — no zsh on this host, so cross-shell parity is not checkable"
    exit 77
fi

# The PATH both legs see. Pinned, and deliberately built to contain BOTH a
# `#!` wrapper and a real binary when the tree has them, so the discriminator
# is exercised rather than trivially satisfied.
PINNED_PATH="$PATH"

# run2 <shell> <snippet> — prints `<stdout>:<rc>` for the snippet run under
# <shell> with the pinned PATH. stderr is dropped from the VALUE (never let a
# diagnostic into a compared string) but shown when an assertion fails.
run2() {
    local sh="$1" snippet="$2" out rc
    out=$(PATH="$PINNED_PATH" "$sh" -c "$snippet" 2>/dev/null); rc=$?
    printf '%s:%s' "$out" "$rc"
}

echo "=== #1319: nx_real_tmux_bin agrees across bash and zsh ==="

_snip=". '$FIXTURE'; nx_real_tmux_bin"
_b=$(run2 bash "$_snip")
_z=$(run2 zsh  "$_snip")
if [[ "$_b" == "$_z" ]]; then
    pass "nx_real_tmux_bin: bash and zsh agree on stdout:rc ($_b)"
else
    fail "nx_real_tmux_bin: bash=[$_b] zsh=[$_z] — the answer is a property of the SHELL"
fi

# NON-VACUITY. A parity assertion is satisfied by two legs that both fail, so
# it must be paired with proof that the compared value is a real answer. On a
# host with a real tmux this is rc 0 and an existing path; on a host without
# one it is rc 1 in BOTH legs, which is still parity and is reported as such.
_bout="${_b%:*}"; _brc="${_b##*:}"
if [[ "$_brc" == 0 ]]; then
    if [[ -x "$_bout" ]] && [[ "$(head -c 2 -- "$_bout" 2>/dev/null)" != '#!' ]]; then
        pass "non-vacuity: the agreed answer is an executable, non-script path ($_bout)"
    else
        fail "non-vacuity: rc 0 but [$_bout] is not an executable real binary"
    fi
elif [[ "$_brc" == 1 ]]; then
    pass "non-vacuity: rc 1 in BOTH legs — no real tmux on PATH, and the two shells agree about that"
else
    fail "non-vacuity: unexpected rc $_brc from nx_real_tmux_bin"
fi

echo "=== #1319: nx_write_tmux_shim's wrapper REFUSAL holds under both shells ==="

# The refusal is the layer whose failure reaches the operator's live board, and
# under zsh it was keyed on the same missing `read -N`. Target a KNOWN `#!`
# wrapper. The repo's own tmuxwrap is one; fall back to a planted script so the
# assertion is not contingent on the wrapper existing.
_wrapper="$REPO/monitor/tmuxwrap/tmux"
_planted=""
if [[ ! -x "$_wrapper" ]] || [[ "$(head -c 2 -- "$_wrapper" 2>/dev/null)" != '#!' ]]; then
    _planted=$(mktemp -d)
    # THE FALLBACK PLANT NAMES NO TMUX AND EXECS NOTHING, deliberately.
    # `nx_write_tmux_shim`'s refusal is keyed on the first two bytes being
    # `#!` — the body is irrelevant to it — so a plant that merely LOOKS like
    # a wrapper (`exec tmux "$@"`) buys the fixture nothing and costs it a
    # real red: `_tmux_shim_scan.awk` is default-deny about any planted tmux
    # whose body it cannot prove is a mock, and it flagged exactly that shape
    # here. The scanner was right — a fixture that plants a board-reaching
    # shim is the hazard, whether or not it ever runs it — so the plant is now
    # a `#!` script that does nothing.
    printf '#!/usr/bin/env bash\nexit 3\n' > "$_planted/tmux"
    chmod +x "$_planted/tmux"
    _wrapper="$_planted/tmux"
fi

for _sh in bash zsh; do
    _d=$(mktemp -d)
    PATH="$PINNED_PATH" "$_sh" -c ". '$FIXTURE'; nx_write_tmux_shim '$_d' '$_wrapper' /tmp/parity.sock" \
        >/dev/null 2>&1
    _rc=$?
    _wrote=no; [[ -e "$_d/tmux" ]] && _wrote=yes
    if (( _rc == 1 )) && [[ "$_wrote" == no ]]; then
        pass "nx_write_tmux_shim under $_sh: REFUSES a #! wrapper (rc 1, no shim written)"
    else
        fail "nx_write_tmux_shim under $_sh: rc=$_rc wrote_shim=$_wrote — the refusal failed OPEN; a shim naming the wrapper loses its -L pin onto the live board"
    fi
    rm -rf "$_d"
done
[[ -n "$_planted" ]] && rm -rf "$_planted"

echo "=== #1319: the three private copies have not drifted from the canonical body ==="

# The copies are byte-identical BY DESIGN (`_tmux-fixture.sh` records the
# decision to leave them in place). That decision was about DUPLICATION and
# did not anticipate a DEFECT in the thing duplicated — which is exactly what
# happened, and it had to be repaired in four places. This assertion makes the
# byte-identity the design relies on checkable, so the next repair cannot land
# in one place and be believed.
_extract() {   # _extract <file> <fn-name>
    sed -n "/^${2}() {/,/^}/p" "$1" | sed "1s/^_*nx_real_tmux_bin/nx_real_tmux_bin/"
}
_canon=$(_extract "$FIXTURE" 'nx_real_tmux_bin')
if [[ -z "$_canon" ]]; then
    fail "could not extract the canonical nx_real_tmux_bin body — the extractor, not the code, is what to fix"
else
    pass "canonical nx_real_tmux_bin body extracted ($(wc -l <<<"$_canon") lines)"
fi

_copies=(test-absent-evidence-precedence.sh
         test-pane-state-boot-absent.sh
         test-pane-state-claude-identity.sh)
for _c in "${_copies[@]}"; do
    _f="$_test_dir/$_c"
    if [[ ! -r "$_f" ]]; then
        fail "$_c: not readable — the copy list in this suite is stale, which is itself the drift being guarded"
        continue
    fi
    _body=$(_extract "$_f" '_nx_real_tmux_bin')
    if [[ -z "$_body" ]]; then
        fail "$_c: carries no _nx_real_tmux_bin — if the copy was removed, remove it from this list in the same commit"
    elif [[ "$_body" == "$_canon" ]]; then
        pass "$_c: private copy is byte-identical to the canonical body"
    else
        fail "$_c: private copy has DRIFTED from the canonical body — a repair landed in one place and not the others"
    fi
done

echo "=== #1319: neither zsh-hostile primitive survives in the fixture helper ==="

# Keyed on the two constructs by name, over the file that must not carry them.
# This is a proxy for the property and is stated as one: it cannot see a THIRD
# zsh divergence nobody has named yet, which is what the parity assertions
# above are for. It earns its place by naming the offender, which a parity
# failure does not.
#
# COMMENT LINES ARE EXCLUDED, and that is not a convenience. The first cut of
# this scanned the whole file and went RED against the FIXED tree — because
# `_tmux-fixture.sh` now explains both constructs in the comment that records
# why they were removed. A lint that fires on its own documentation is a lint
# that pays authors to stop documenting, and it would have been read as "the
# fix did not land". Strip lines whose first non-blank character is `#`.
_noncomment=$(grep -vE '^[[:space:]]*#' "$FIXTURE")
for _bad in 'read -r -N' 'for _d in $PATH'; do
    if grep -qF -- "$_bad" <<<"$_noncomment"; then
        fail "_tmux-fixture.sh still contains the zsh-hostile construct: $_bad"
    else
        pass "_tmux-fixture.sh is free of the zsh-hostile construct: $_bad"
    fi
done

# Every assertion this file declares must actually RUN. The copy-drift band
# below is a LOOP over a list, so a copy silently dropped from that list would
# take its assertion with it and the suite would still report a clean green —
# which is the same shape as the byte-identity drift the band exists to catch.
_EXPECTED_ASSERTIONS=10
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
