#!/usr/bin/env bash
# test-shell-files.sh — the shared shell-file derivation (your-org/nexus-code#792).
#
# `monitor/shell-files.sh` answers ONE question — "is this file a shell file?" —
# for the two cc-harness kill guards and the watcher's ambient-option scope
# guard. Before it existed the question had four independent implementations
# and four different answers, and three of them were blind to `monitor/ng`.
#
# WHAT THIS SUITE IS ACTUALLY FOR, stated because it is not the obvious thing:
# it is not here to check that `shf_class` returns the right string. It is here
# to pin the property the whole issue turns on —
#
#   **an extensionless executable added TOMORROW is covered with nobody
#   remembering to add it.**
#
# The rejected fix was `find … \( -name '*.sh' -o -name 'ng' \)`, a one-element
# allowlist. It passes any test that only asks about files that exist today. So
# the decisive fixtures below plant files under names that appear NOWHERE in
# this repo — `brand-new-tool`, `future-thing` — and a list-based enumerator
# cannot pass them however long the list.
#
# ASSERTION SHAPE. Almost every assertion here is POSITIVE: it names something
# that must be FOUND. `#793`(b) is the reason — a guard built out of absences
# ("X is not in the output") is satisfied by an enumerator that produced no
# output at all, which is the exact failure being guarded against. Where an
# absence IS the property under test (a non-script must not be classified), it
# is paired with a positive twin on byte-identical content, so the pair can only
# both pass if the classifier genuinely discriminates.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_self_dir/../.." && pwd)
LIB="$REPO_ROOT/monitor/shell-files.sh"

[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

TMP=$(mktemp -d -t shf-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

_plant() {   # <name> <content> -> path
    printf '%s\n' "$2" > "$TMP/$1"
    printf '%s' "$TMP/$1"
}

# --- 1. the self-maintaining arm -------------------------------------------
echo "=== arm 2 (shebang): a file nobody enumerated is classified anyway ==="

# THE DECISIVE ONE. Nothing in this repo names `brand-new-tool`. A list cannot
# pass this; a derivation cannot fail it.
assert_eq "an extensionless bash executable nobody has heard of is 'shell'" \
    "$(shf_class "$(_plant brand-new-tool '#!/usr/bin/env bash
echo hi')")" shell

assert_eq "…and so is the next one, under a different unknown name" \
    "$(shf_class "$(_plant future-thing '#!/bin/sh
echo hi')")" shell

assert_eq "a direct #!/bin/bash path resolves" \
    "$(shf_class "$(_plant direct-bash '#!/bin/bash
:')")" shell
assert_eq "a zsh shebang resolves" \
    "$(shf_class "$(_plant zsh-tool '#!/usr/bin/env zsh
:')")" shell

# `env -S` is the shape that defeats a naive "the word after env" read: that
# read returns `-S`, matches no interpreter, and drops the file SILENTLY —
# which is the failure mode of the whole issue in miniature.
assert_eq "env -S does not swallow the interpreter" \
    "$(shf_class "$(_plant env-s-tool '#!/usr/bin/env -S bash -e
:')")" shell
assert_eq "an env VAR=value assignment does not swallow the interpreter" \
    "$(shf_class "$(_plant env-var-tool '#!/usr/bin/env LC_ALL=C bash
:')")" shell

# A CRLF first line yields an interpreter of `bash<CR>` unless the CR is
# stripped, which matches nothing and excludes the file with no diagnostic.
printf '#!/usr/bin/env bash\r\n:\r\n' > "$TMP/crlf-tool"
assert_eq "a CRLF shebang still resolves (the CR is stripped)" \
    "$(shf_class "$TMP/crlf-tool")" shell

# --- 2. discrimination — inclusion must be EARNED --------------------------
echo "=== the classifier discriminates (it does not just say yes) ==="
#
# Each of these is byte-identical in body to something classified `shell`
# above. If the classifier were broken into accepting everything, arm-2's
# passes would be worthless — these are what make them mean something.
assert_eq "no shebang, no extension, no startup name => not a script" \
    "$(shf_class "$(_plant plain-notes 'echo hi')" || echo NONE)" NONE
assert_eq "a non-shell shebang => not 'shell'" \
    "$(shf_class "$(_plant ruby-tool '#!/usr/bin/env ruby
:')" || echo NONE)" NONE
assert_eq "a python shebang classifies as python, not shell" \
    "$(shf_class "$(_plant py-tool '#!/usr/bin/env python3
pass')")" python
assert_eq "a perl shebang classifies as perl, not shell" \
    "$(shf_class "$(_plant pl-tool '#!/usr/bin/env perl
1;')")" perl
assert_eq "a bare '#' comment first line is not a shebang" \
    "$(shf_class "$(_plant hash-only '# just a comment
5.2')" || echo NONE)" NONE

# Arm 0 — transient junk. An extension glob excluded these for free; a shebang
# derivation does not, because they are byte-copies carrying a real shebang.
# This is not hypothetical: an NFS silly-rename artifact entered the population
# mid-run and made the residue manifest disagree with itself between two
# invocations seconds apart.
for j in '.nfs00000007821bbd2e00060460' 'tool.sh~' 'tool.sh.orig' 'tool.sh.bak'; do
    assert_eq "transient junk '$j' is excluded despite a real shebang" \
        "$(shf_class "$(_plant "$j" '#!/usr/bin/env bash
:')" || echo NONE)" NONE
done

# `monitor/ci-bash-version` is the live instance of that last one: a data file
# whose first line is a comment. It must NOT enter any lint's population.
assert_eq "monitor/ci-bash-version (data, '#' but no '!') is not a script" \
    "$(shf_class "$REPO_ROOT/monitor/ci-bash-version" || echo NONE)" NONE

# --- 3. arm 1 (extension) ---------------------------------------------------
echo "=== arm 1 (extension): sourced libraries carry no shebang ==="
#
# Arm 2 alone would be a plausible-sounding and badly wrong derivation: the
# majority of this repo's shell corpus is SOURCED libraries, which are never
# executed and frequently have no shebang at all. This pins that arm 1 is
# load-bearing rather than legacy.
assert_eq "a .sh library with NO shebang is still 'shell'" \
    "$(shf_class "$(_plant lib_no_shebang.sh '_f() { :; }')")" shell
assert_eq "watcher/_lib.sh (real, sourced) is 'shell'" \
    "$(shf_class "$REPO_ROOT/monitor/watcher/_lib.sh")" shell

# --- 4. arm 3 (startup files) ----------------------------------------------
echo "=== arm 3 (startup names): no extension AND no shebang ==="
#
# The one arm that is a list, and it owes an argument (see the header): its
# vocabulary is fixed by bash's and zsh's documented startup sequences, which
# this repo does not get a vote in. Adding a FILE can never add a startup-file
# NAME, so it cannot rot the way `-o -name 'ng'` rotted. Pinned so that
# growing it is a deliberate, reviewed edit.
for n in .zshenv .zshrc .zprofile .zlogin .bashrc .bash_profile .profile; do
    assert_eq "startup file '$n' is 'shell'" \
        "$(shf_class "$(_plant "$n" 'export PATH=/x:$PATH')")" shell
done
# And the four live ones, by path, so this is a claim about the tree.
for n in .zshenv .zshrc .zprofile .zlogin; do
    assert_eq "the LIVE monitor/shellenv/$n is 'shell'" \
        "$(shf_class "$REPO_ROOT/monitor/shellenv/$n")" shell
done

# --- 5. the #792 population, on the real tree -------------------------------
echo "=== the eleven files every '*.sh' glob was blind to ==="
#
# Positive membership, one assertion per file. Listing them here is NOT the
# rotting kind of list: this is a test asserting that a DERIVATION covers known
# members, not an enumerator deriving its answer from a list. If a twelfth
# appears, the derivation covers it and this file simply does not mention it —
# which is the correct behaviour and the difference the whole issue is about.
_ext_less=$(bash "$LIB" --extensionless "$REPO_ROOT/monitor")
for f in ng ghwrap/gh pipwrap/pip notifywrap/sandbox-notify \
         client/nexus-request client/nexus-reply-watch git-https-setup \
         shellenv/.zshenv shellenv/.zshrc shellenv/.zprofile shellenv/.zlogin; do
    assert_contains "monitor/$f is in the derived shell population" \
        "$_ext_less" "monitor/$f"
done

# `pipwrap/pip3` is a SYMLINK to `pipwrap/pip`. Excluded by `-type f`, and
# deliberately: scanning both would double-report every hit in that file.
assert_not_contains "the pip3 SYMLINK is not double-counted" \
    "$_ext_less" "pipwrap/pip3"

# --- 6. NON-VACUITY ---------------------------------------------------------
echo "=== non-vacuity: an enumeration that found nothing must be LOUD ==="
#
# The floor is the backstop for every consumer. It is asserted in both
# directions, because a floor that cannot be observed failing is not evidence —
# the same argument the tmux lint's `--selftest` makes about itself.
_n_shell=$(shf_count "$REPO_ROOT/monitor" shell)
_n_script=$(shf_count "$REPO_ROOT/monitor" script)
_n_glob=$(find "$REPO_ROOT/monitor" -type f \
            \( -name '*.sh' -o -name '*.zsh' -o -name '*.bash' \) | wc -l)

assert_eq "the derived population clears its floor" \
    "$(shf_require_floor "$REPO_ROOT/monitor" shell 300 t >/dev/null 2>&1 \
        && echo ok || echo short)" ok
assert_eq "…and the floor is observed FAILING when set above the truth" \
    "$(shf_require_floor "$REPO_ROOT/monitor" shell 99999 t >/dev/null 2>&1 \
        && echo ok || echo short)" short

# The derivation must be a strict SUPERSET of the old glob — never a
# replacement that quietly drops members. Sanity-checked against a known total
# rather than asserted, because a count behind a claim is exactly where this
# repo's silent zeros live.
assert_eq "the derived population strictly EXCEEDS the old *.sh glob ($_n_shell > $_n_glob)" \
    "$(( _n_shell > _n_glob ))" 1
assert_eq "the script class is at least the shell class ($_n_script >= $_n_shell)" \
    "$(( _n_script >= _n_shell ))" 1

_missing=0
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    shf_is_shell "$f" || { echo "    NOT covered: $f" >&2; _missing=$((_missing+1)); }
done < <(find "$REPO_ROOT/monitor" -type f \
            \( -name '*.sh' -o -name '*.zsh' -o -name '*.bash' \) )
assert_eq "every file the OLD glob saw is still seen (no silent regression)" \
    "$_missing" 0

# THE DECLARED GAP, RE-MEASURED ON THE LIVE TREE (your-org/nexus-code#799
# skeptic, F-3). `shell-files.sh`'s boundary note names "executed as
# `bash somefile` with no shebang and no shell name" as its unsafe-direction
# gap and claims zero live occurrences. That claim used to point at the fixture
# assertion above — which exercises the CLASSIFIER on a planted file, i.e. it
# checks the gap EXISTS, not that nothing falls into it. A prose promise about
# a check that did not exist, in the file arguing prose cannot be made to fail.
#
# This is the check. An executable regular file that `shf_class` cannot
# classify is a candidate for the gap. Sanity-checked against a known total in
# the same breath, because a count behind a claim is exactly where this repo's
# silent zeros live: a broken scan would report `0 unclassified` AND
# `0 scanned`, and only the second number gives it away.
_unclassified=""; _scanned=0
while IFS= read -r -d '' f; do
    _scanned=$(( _scanned + 1 ))
    [[ -x "$f" ]] || continue
    shf_class "$f" >/dev/null 2>&1 || _unclassified+="$f"$'\n'
done < <(find "$REPO_ROOT/monitor" \
            \( -name .git -o -name .state -o -name node_modules \) -prune -o \
            -type f -print0 2>/dev/null)
assert_eq "the live-tree sweep examined a real population (not a silent zero)" \
    "$(( _scanned > 400 ))" 1
assert_empty "no executable file on the tree falls into the declared shebang gap ($_scanned scanned)" \
    "$_unclassified"

# --- 7. the consumers actually use it ---------------------------------------
echo "=== the shared helper is SHARED (not a fourth implementation) ==="
#
# `#775`'s lesson: two implementations of one notion drift into the identical
# bug, and they did. The point of this file is defeated if a consumer keeps its
# own `find`. So assert the consumers source it, and assert no consumer still
# carries the one-element allowlist that prompted the issue.
for c in monitor/cc-harness/lint-no-tmux-server-kill.sh \
         monitor/cc-harness/lint-no-mass-kill.sh \
         monitor/watcher/test-ambient-shell-option-scope.sh \
         monitor/watcher/early-exit-readers.sh; do
    assert_contains "$c sources the shared enumerator" \
        "$(cat "$REPO_ROOT/$c")" 'shell-files.sh'
done

# The literal pattern `#792` was filed about, asserted absent from the
# consumers' CODE.
#
# DATA IS NOT CODE — and this assertion learned that the hard way, on its first
# run, against its own author. Every one of those files now DISCUSSES
# `-name 'ng'` in its header, because explaining why the one-element allowlist
# was rejected is the substance of the fix. Matching raw text therefore reported
# a violation in the very commit that removed the last real one. Full-line
# comments are stripped first, exactly as `_tmux_kill_scan.awk` and `_aso_code`
# do it, and for the same reason: making authors avoid naming a banned idiom in
# prose is how a guard decays into something people route around.
_strip_comments() { sed -E 's/^[[:space:]]*#.*$//' "$@"; }
_consumers=$(_strip_comments "$REPO_ROOT/monitor/cc-harness/lint-no-tmux-server-kill.sh" \
                             "$REPO_ROOT/monitor/cc-harness/lint-no-mass-kill.sh" \
                             "$REPO_ROOT/monitor/watcher/early-exit-readers.sh" \
                             "$REPO_ROOT/monitor/watcher/test-ambient-shell-option-scope.sh")
# Non-vacuity on the corpus itself: an empty haystack satisfies any
# `assert_not_contains`, which is the vacuity `#793`(b) is about. Pin that the
# strip left real code behind before trusting the absence below.
assert_eq "the corpus read for the next assertion is non-empty after stripping" \
    "$(( $(printf '%s' "$_consumers" | wc -c) > 20000 ))" 1
assert_contains "…and still contains real code" "$_consumers" 'shf_'
assert_not_contains "no consumer still carries the one-element allowlist" \
    "$_consumers" "-name 'ng'"

th_summary_and_exit
