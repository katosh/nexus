#!/usr/bin/env bash
# Tests for the empty --target guard and the runbook-snippet lint
# (your-org/nexus-code#459, round 3).
#
# The defect: `#461` swept the repo for hard-coded `orchestrator` window names
# and, on a copy-pasteable surface, introduced a new instance of the very class
# it was closing — asserting a state that was never established.
#
#   skills/nexus.cc-update/GUIDE.md:499
#       `monitor/watcher/launcher.sh --target "$TARGET_WINDOW"`
#
# `$TARGET_WINDOW` is UNDEFINED there. Its only assignment is 137 lines earlier
# (:362), inside a DIFFERENT fenced block, run by a DIFFERENT actor (the
# orchestrator, as its final act) in a different shell. A human evaluator
# copy-pasting the line gets `--target ''` in any shell without `set -u`.
#
#   monitor/watcher/launcher.sh:92
#       --target)  TARGET="${2:-}"; shift 2 ;;
#
# An EMPTY argument then OVERRIDES the config default resolved at :82, so the
# watcher launches with no coordinator window to paste into: a nexus that looks
# healthy and reaches nobody.
#
# This surface is copy-pasted by a human evaluator on OTHER operators' nexuses.
# Ours is immune (our target window really is named `orchestrator`), which is
# exactly why a broken fix ships unnoticed by us — and why the doc lint below
# exists rather than a single-line correction.
#
# Assertions:
#   A  launcher.sh --target ''   -> exit 2, loud, no side effect.
#   B  launcher.sh --window ''   -> exit 2 (same class, same flag shape).
#   C  launcher.sh --target      -> exit 2 (flag present, value missing).
#   D  NO REGRESSION: a non-empty --target still works, and omitting --target
#      still resolves the config default. The guard must refuse only the empty.
#   E  Doc lint: no file in the repo invokes `launcher.sh --target` with a
#      variable that the reader has no way to have defined.
#   F  Doc lint: every `$VAR` in GUIDE.md is either ambient or assigned inside
#      the SAME fenced block that references it. Block scope is the right
#      granularity: separate blocks are separate shells run by separate actors.
#   G  Doc lint: no doc hard-codes `--target orchestrator` (the thing `#461`
#      was sweeping away; a hard-coded name kills nothing on a nexus whose
#      window is named otherwise).
#   H  Every fenced bash block in GUIDE.md parses (`bash -n`).
#   I  NON-VACUITY of F/H itself: the lint still catches planted defects, and
#      does not cry wolf on real bash idioms. F/H is an assert-empty, and an
#      assert-empty passes just as loudly when the checker has been broken into
#      silence — see your-org/nexus-code#744, where this lint recognised only
#      LINE-INITIAL `VAR=` and so reported `hit` (in `tot=0; hit=0`) and `idx`
#      (in `read -r idx _`) as unassigned, reddening six blocking bands against
#      a correct snippet. Both directions are pinned to runtime fixtures.
#
# A/B/C/E/F/G all FAIL on pre-fix source. D and H pass in both directions, by
# design — they are the no-regression half. I fails on a checker mutated in
# ANY of four directions (all measured, 2026-08-07):
#   * revert the #744 fix          -> reds `I: accepts a second assignment
#                                     after a ;`, and F/H
#   * delete the command anchor    -> reds three `I: flags …` cases
#   * drop the assignment PREFIX   -> reds `I: accepts IFS= read -r NAME` and
#                                     `I: accepts while IFS=: read -r a b`
#   * revert the #775 fix (narrow  -> reds the five `I: accepts …` cases added
#     the PREFIX value back to an     for it, and NOTHING else: 34 passed,
#     unquoted run, and drop it       5 failed, which is exactly the assertion
#     from the declaration arms)      count #775 records the branch shipping
#                                     with
#
#   git stash push monitor/watcher/launcher.sh skills/nexus.cc-update/GUIDE.md CLAUDE.md \
#     && bash monitor/watcher/test-launcher-empty-target.sh ; git stash pop
#
# `--instance-status` makes A-D safe to run for real: it prints the instance-lock
# state and exits WITHOUT spawning a watcher or touching tmux. The guard fires
# during argument parsing, before that path is even reached.
#
# Run: bash monitor/watcher/test-launcher-empty-target.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
LAUNCHER="$_test_dir/launcher.sh"
GUIDE="$_repo_root/skills/nexus.cc-update/GUIDE.md"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got [$2] want [$3]"; }
assert_contains() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1" "missing [$3] in <<$2>>"; }

[[ -x "$LAUNCHER" ]] || { echo "missing $LAUNCHER" >&2; exit 1; }
[[ -f "$GUIDE" ]]    || { echo "missing $GUIDE" >&2; exit 1; }

# The refusal message shows the CONFIG-RESOLVED default, not a fixed name.
# Asserting the literal `orchestrator` here reds spuriously on any nexus
# whose `monitor.target_window` differs — the exact population #459/#475
# protect, and one CI (no nexus.yml) is blind to (audit-skeptic finding,
# 2026-07-09). Compute the expectation the same way launcher.sh does at
# its `TARGET=` line, so the assertion tracks the launcher's own
# resolution on every nexus, config or fallback alike.
_cfg="$_repo_root/config/load.sh"
EXPECTED_TARGET="${MONITOR_TARGET:-$("$_cfg" monitor.target_window orchestrator 2>/dev/null)}"

# ============================================================
echo '=== A/B/C: an empty flag value FAILS LOUD (never silently overrides config) ==='
# ============================================================
out=$(timeout 30 bash "$LAUNCHER" --target "" --instance-status 2>&1); rc=$?
assert_eq       "A: --target '' -> exit 2"            "$rc" "2"
assert_contains "A: --target '' -> names the flag"    "$out" "--target requires a non-empty value"
assert_contains "A: --target '' -> blames the caller" "$out" "unset variable in the caller"
assert_contains "A: --target '' -> shows the (dynamically resolved) default it refused to clobber" \
    "$out" "Resolved defaults: --target '$EXPECTED_TARGET'"

out=$(timeout 30 bash "$LAUNCHER" --window "" --instance-status 2>&1); rc=$?
assert_eq       "B: --window '' -> exit 2"         "$rc" "2"
assert_contains "B: --window '' -> names the flag" "$out" "--window requires a non-empty value"

# `--target` as the final argument is worse than it looks pre-fix: `shift 2`
# with one positional left FAILS and shifts NOTHING, so `$1` stays `--target`
# and the parse loop spins forever (no `set -e` to stop it). Pre-fix this call
# does not exit 1, it HANGS — `timeout` reports 124. Assert the exact code, so
# a hang can never be mistaken for a tidy usage error.
out=$(timeout 30 bash "$LAUNCHER" --target 2>&1); rc=$?
assert_eq "C: --target with no value at all -> exit 2 (pre-fix: 124, an infinite parse loop)" "$rc" "2"

# ============================================================
echo '=== D: no regression — a real target works, and the default still resolves ==='
# ============================================================
# If the guard refused more than the empty string it would be worse than the bug.
timeout 30 bash "$LAUNCHER" --target orchestrator --instance-status >/dev/null 2>&1
assert_eq "D: --target orchestrator still accepted" "$?" "0"
timeout 30 bash "$LAUNCHER" --target some-other-window --instance-status >/dev/null 2>&1
assert_eq "D: an arbitrary non-empty target accepted" "$?" "0"
timeout 30 bash "$LAUNCHER" --instance-status >/dev/null 2>&1
assert_eq "D: omitting --target resolves the config default" "$?" "0"

# ============================================================
echo '=== E/G: no doc hands launcher.sh an undefined variable, or a hard-coded name ==='
# ============================================================
# Fixtures are captured terminal output, not instructions — exclude them.
_docs() { git -C "$_repo_root" ls-files '*.md' 2>/dev/null | grep -v '^monitor/watcher/fixtures/' || true; }

undef_target=$(cd "$_repo_root" && _docs | xargs grep -nF -- 'launcher.sh --target "$' 2>/dev/null || true)
assert_eq "E: no doc invokes launcher.sh --target with a shell variable" "$undef_target" ""

# G must be whitespace-insensitive. Prose wraps: CLAUDE.md had
#   `... launcher.sh --replace --target
#   orchestrator`
# which no line-based grep can see. A line-based check here PASSES on pre-fix
# source — a false pass, and precisely the kind of unverified assertion this
# whole issue is about. Collapse whitespace first, then match.
hardcoded=$(cd "$_repo_root" && _docs | while IFS= read -r f; do
    python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
flat = re.sub(r'\s+', ' ', open(p, encoding='utf-8', errors='replace').read())
for m in re.finditer(r'launcher\.sh[^`]{0,80}?--target orchestrator', flat):
    print("%s: %s" % (p, m.group(0)))
PY
done)
assert_eq "G: no doc hard-codes --target orchestrator (whitespace-insensitive)" "$hardcoded" ""

# ============================================================
echo '=== F/H: every GUIDE.md snippet is self-contained and parses ==='
# ============================================================
# F is the assertion that would have caught the original defect. The broken line
# lived in PROSE, not in a fenced block, so a fenced-block-only check misses it:
# scan the whole document, and require that any variable reference sit in the
# same fenced block as its own assignment.
#
# The linter is written to a FILE rather than piped inline, because section I
# re-runs it against planted fixtures. A lint whose own correctness is never
# exercised is the failure mode this repo keeps paying for: in CI, relaxing a
# checker until it stops complaining is typographically identical to fixing it.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
LINT="$WORK/guide_lint.py"
cat > "$LINT" <<'PY'
import re, shlex, subprocess, sys
path = sys.argv[1]
lines = open(path).read().split('\n')

# Ambient: exported into every nexus shell, so a bare reference is legitimate.
AMBIENT = {'NEXUS_ROOT', 'HOME', 'PATH', 'USER', 'PWD'}

# --- what counts as "assigned" ------------------------------------------
# A bash name is bound by a word in COMMAND position -- not merely at the
# start of a LINE -- and by builtins that bind without a literal `=`.
# Anchoring on `^` alone (as this lint did until your-org/nexus-code#744) saw
# `tot=0` in `tot=0; hit=0` but not `hit`, and did not know `read -r idx _`
# binds `idx` at all. So GUIDE.md's live re-check snippet -- correct,
# idiomatic, exercised bash -- reported two phantom unassigned variables and
# reddened six blocking CI bands. The lint failed CLOSED (a false alarm, not
# a false green), which is why it was safe to fix properly rather than to
# contort the guide around it.
#
# The anchor is a command SEPARATOR, and that is also what keeps the fix from
# over-relaxing: `--target=1` and `echo "a=b"` do NOT register as assignments,
# because they are preceded by `-` and by `"a`, not by a separator. Section I
# of this suite holds both directions to the fire.
#
# A narrower version of this fix — `(?:^|;)` plus an UNANCHORED `\bread\b` —
# also turns GUIDE.md green, and was measured before being superseded. Its
# residual gaps, all now covered by section I:
#   * FALSE NEGATIVE: a COMMENT containing the word `read` ("# read the status
#     line") binds its following words, so a genuinely unassigned `$line` in
#     that block passes silently. That is a hole in the very defect class F
#     exists to catch, which is why `read` is anchored in command position here.
#   * FALSE POSITIVES on `true && export Q=1`, `mapfile -t arr` and
#     `printf -v out` — the same crying-wolf that reddened six bands, merely
#     waiting on a different idiom.
# It is NOT, however, a strict superset: the narrower form ACCEPTS
# `IFS= read -r NAME` and `while IFS=: read -r a b`, which command-position
# anchoring flags unless `PREFIX` above is applied. Both are pinned in section
# I so that trade cannot silently reappear.
CMD = r'(?:^|[\n;&|(){}!]|\b(?:do|then|else|elif|while|until|if|time)\s)\s*'
DECL = r'(?:(?:export|local|declare|typeset|readonly)\s+(?:-\w+\s+)*)?'
# A command word may be preceded by one or more ASSIGNMENT PREFIXES scoped to
# that command — `IFS= read -r NAME`, `while IFS=: read -r a b`. Without this,
# anchoring on a command separator REGRESSES against the unanchored form: the
# prefix sits between the separator and `read`, so the bind is missed and a
# correct snippet is flagged. That idiom is not exotic — CLAUDE.md prescribes
# `while IFS= read -r` as the shell-portable enumeration, it occurs 202 times
# under monitor/, and line 143 of THIS file uses it.
#
# The VALUE may be quoted and may contain whitespace, and that is not a nicety
# (your-org/nexus-code#775). The first version of this allowance was
# `[^\s;|&]*` — an unquoted run — which is exactly the value shapes its author's
# repro happened to use. It stops at the space inside `IFS=" "`, so the prefix
# ends mid-token, `read` is not in command position, and `$x` reads as
# unassigned. `IFS=" " read -r` is the form CLAUDE.md actually prescribes.
# The `$'…'` arm is the third shape, and it is the one that matters most for a
# lint about SHELL PORTABILITY: `IFS=$' \t' read` is how you split on tab.
#
# HOW THIS GAP SURVIVED, which is the part worth not repeating: the #744
# skeptic raised it, supplied the narrow one-liner, then CORRECTED its own
# remedy on finding the gap wider than its two named examples — eight minutes
# after `2a1071b` had already adopted the first version. A correction that
# arrives after its subject is consumed does not retroactively apply. So the
# fix below is deliberately written to the CLASS (any assignment prefix, any
# value shape) and not to the two shapes the issue names, and section I pins
# five of them so the trade cannot silently reappear.
ASSIGN = r'''[A-Za-z_]\w*=(?:"[^"]*"|\$?'[^']*'|[^\s;|&]*)'''
PREFIX = r'(?:' + ASSIGN + r'\s+)*'

# Options that consume the FOLLOWING token. Per-command, because `-t` takes an
# argument for `read` (timeout) and takes NONE for `mapfile` (strip newlines):
# one shared table silently ate the array name in `mapfile -t arr`.
_ARGOPT = {'read': set('adinNptu'), 'mapfile': set('dnOsCcu'), 'readarray': set('dnOsCcu')}


def _trailing_names(cmd, argstr):
    """Names bound by `read` / `mapfile` / `readarray`: the bare words left
    once the option list is consumed. shlex keeps a quoted option argument
    (`read -p "enter: " v`) as ONE token; on unbalanced quotes it raises and
    we fall back to a whitespace split, which can over-report -- the safe
    direction for a lint that fails closed."""
    try:
        toks = shlex.split(argstr)
    except ValueError:
        toks = argstr.split()
    out, i = set(), 0
    argopt = _ARGOPT[cmd]
    while i < len(toks):
        t = toks[i]
        if t.startswith('-') and len(t) > 1:
            if t == '--':
                i += 1
                continue
            if t[-1] in argopt:
                if cmd == 'read' and t[-1] == 'a' and i + 1 < len(toks):
                    out.add(toks[i + 1])      # `read -a NAME` binds the array
                i += 2
            else:
                i += 1
            continue
        if not re.match(r'^[A-Za-z_]\w*$', t):
            break                              # not a name: end of the list
        out.add(t)
        i += 1
    return out


def names_bound(body):
    out = set()
    # NAME=v / export NAME=v / declare -a NAME=v / NAME[i]=v — and the same
    # after an assignment prefix (`LC_ALL=C declare -i n=0`). PREFIX is applied
    # to the DECLARATION arms too, not only to `read` below: those two arms are
    # where `LC_ALL=C declare -i n=0` was being missed (your-org/nexus-code#775).
    out |= set(re.findall(CMD + PREFIX + DECL + r'([A-Za-z_]\w*)(?:\[[^\]]*\])?=',
                          body, re.M))
    # The prefix run binds its OWN names as well as scoping the command's:
    # `LC_ALL=C declare -i n=0` binds both LC_ALL and n. The arm above returns
    # only the innermost, so collect the prefix separately rather than leave a
    # later `$LC_ALL` reading as unassigned — a false alarm of exactly the kind
    # this fix exists to remove.
    for m in re.finditer(CMD + r'(?:' + ASSIGN + r'\s+)+', body, re.M):
        out |= set(re.findall(r'([A-Za-z_]\w*)=', m.group(0)))
    # export NAME / declare -i NAME / readonly NAME  (declared, not yet valued)
    out |= set(re.findall(
        CMD + PREFIX +
        r'(?:export|declare|typeset|readonly|local)\s+(?:-\w+\s+)*([A-Za-z_]\w*)\b',
        body, re.M))
    out |= set(re.findall(r'\b(?:for|select)\s+([A-Za-z_]\w*)\s+in\b', body))
    out |= set(re.findall(r'\(\(\s*([A-Za-z_]\w*)\s*(?:[-+*/%|&^]?=|\+\+|--)', body))
    out |= set(re.findall(r'\blet\s+["\']?([A-Za-z_]\w*)', body))
    out |= set(re.findall(r'\bprintf\s+(?:-\w+\s+)*-v\s+([A-Za-z_]\w*)', body))
    out |= set(re.findall(r'\bgetopts\s+\S+\s+([A-Za-z_]\w*)', body))
    for m in re.finditer(CMD + PREFIX + r'(mapfile|readarray|read)\b([^\n;|&)]*)', body, re.M):
        out |= _trailing_names(m.group(1), m.group(2))
    return out


blocks, cur, lang, start = [], None, None, 0
for i, l in enumerate(lines, 1):
    m = re.match(r'^\s*```(\w*)\s*$', l)
    if m and cur is None:
        lang, cur, start = m.group(1), [], i
    elif re.match(r'^\s*```\s*$', l) and cur is not None:
        blocks.append((start, i, lang, '\n'.join(cur)))
        cur = None
    elif cur is not None:
        cur.append(l)

in_block = set()
problems = []

for s, e, lang, body in blocks:
    in_block.update(range(s, e + 1))
    assigned = names_bound(body)
    defended = set(re.findall(r'\$\{([A-Za-z_]\w*):[-=?+]', body))
    refs = set(re.findall(r'\$\{?([A-Za-z_]\w*)', body))
    for v in sorted(refs - assigned - AMBIENT - defended):
        problems.append("L%d-%d (fenced): $%s referenced but never assigned in this block" % (s, e, v))
    if lang == 'bash':
        probe = re.sub(r'<[a-zA-Z0-9_.-]+>', 'PLACEHOLDER', body)
        p = subprocess.Popen(['bash', '-n'], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        _, err = p.communicate(probe.encode())
        if p.returncode:
            problems.append("L%d (fenced bash): bash -n failed: %s" % (s, err.decode().strip()[:80]))

# Anything OUTSIDE a fenced block is prose. A variable there has no defining
# shell at all -- this is exactly the GUIDE.md:499 shape.
for i, l in enumerate(lines, 1):
    if i in in_block:
        continue
    for v in re.findall(r'\$\{?([A-Za-z_]\w*)', l):
        if v not in AMBIENT:
            problems.append("L%d (prose): $%s has no defining block -- unrunnable if copy-pasted" % (i, v))

print('\n'.join(problems))
PY

lint=$(python3 "$LINT" "$GUIDE")
assert_eq "F/H: GUIDE.md snippets are self-contained and parse" "$lint" ""

# ============================================================
echo '=== I: the F/H lint is NON-VACUOUS in both directions ==='
# ============================================================
# F/H above is an assert-empty. An assert-empty passes just as loudly when the
# checker has been broken into silence, so on its own it certifies nothing --
# and #744 is precisely a round of this checker being wrong. Both directions
# are therefore held to fixtures composed at RUNTIME (the #682/#693 pattern):
#
#   lint_flags  a defect the checker MUST still catch, named by its variable
#   lint_clean  a real bash idiom it MUST NOT cry wolf on
#
# The must-flag half is what stops a future "fix" from relaxing the regex until
# the complaints stop; the must-clean half is what stops the anchor being
# dropped altogether (which would let `--target=1` and `"a=b"` pass as
# assignments and hollow out F).
lint_out() { printf '%s\n' "$2" > "$WORK/case.md"; python3 "$LINT" "$WORK/case.md"; }
lint_flags() { assert_contains "I: flags $1" "$(lint_out "$1" "$3")" "$2"; }
lint_clean() { assert_eq       "I: accepts $1" "$(lint_out "$1" "$2")" ""; }

lint_flags 'a variable assigned nowhere in the block' '$NOPE' '```bash
echo "$NOPE"
```'
lint_flags 'a CROSS-BLOCK reference (the #459 defect shape)' '$TARGET_WINDOW' '```bash
TARGET_WINDOW=orchestrator
```
```bash
launcher.sh --target "$TARGET_WINDOW"
```'
lint_flags 'a variable in PROSE, with no defining block' '$FOO' 'run it with $FOO now'
lint_flags 'a fenced bash block that does not parse' 'bash -n failed' '```bash
if [ x ; then
```'
lint_flags 'an --opt=value, which does NOT bind a name' '$target' '```bash
cmd --target=1
echo "$target"
```'
lint_flags 'an a=b inside a quoted string, which binds nothing' '$a' '```bash
echo "a=b"
echo "$a"
```'
lint_flags 'the word "read" in a COMMENT, which binds nothing' '$line' '```bash
# read the status line
echo "$line"
```'
lint_flags 'read -t 5 (a timeout argument, not a name)' '$reply' '```bash
read -t 5 -r
echo "$reply"
```'

lint_clean 'a second assignment after a ; (GUIDE.md tot=0; hit=0)' '```bash
tot=0; hit=0
echo "$tot $hit"
```'
lint_clean 'while read -r NAME _ (GUIDE.md re-check (ii))' '```bash
while read -r idx _; do echo "$idx"; done < f
```'
lint_clean 'for NAME in' '```bash
for f in *; do echo "$f"; done
```'
lint_clean 'printf -v NAME' '```bash
printf -v out %s x
echo "$out"
```'
lint_clean 'mapfile -t NAME (-t takes NO argument here)' '```bash
mapfile -t arr < f
echo "${arr[0]}"
```'
lint_clean 'readarray -t -n 5 NAME' '```bash
readarray -t -n 5 xs < f
echo "${xs[0]}"
```'
lint_clean 'declare -i NAME=0' '```bash
declare -i n=0
echo "$n"
```'
lint_clean '(( NAME=1 ))' '```bash
(( c=1 ))
echo "$c"
```'
lint_clean 'read -a NAME (binds the array)' '```bash
read -a items <<<"x"
echo "${items[0]}"
```'
lint_clean 'an export on the right of an && chain' '```bash
true && export Q=1
echo "$Q"
```'
lint_clean 'read -p "quoted prompt" NAME' '```bash
read -p "enter: " v
echo "$v"
```'
# These two are a REGRESSION GUARD, not a nicety. Anchoring `read` in command
# position (the #744 fix) initially broke both, while the narrower unanchored
# form accepted them — so the anchor is only correct WITH the assignment-prefix
# allowance. CLAUDE.md prescribes `while IFS= read -r`, and line 143 of this
# very file uses it.
lint_clean 'IFS= read -r NAME (assignment prefix)' '```bash
IFS= read -r NAME < f
echo "$NAME"
```'
lint_clean 'while IFS=: read -r a b (prefix with a value)' '```bash
while IFS=: read -r a b; do echo "$a $b"; done < f
```'
# your-org/nexus-code#775 — the prefix VALUE may be quoted and may contain
# whitespace. The first allowance was an unquoted run (`[^\s;|&]*`), fitted to
# the two values its repro used, so it ended mid-token on the space inside
# `IFS=" "`. These five hold the CLASS rather than the two shapes the issue
# named: quoted value, quoted value before a DECLARATION (a separate arm of
# names_bound, and the one nothing covered), `$'…'` with whitespace in it,
# several prefixes at once, and the prefix's own name staying bound.
lint_clean 'IFS=" " read -r NAME (quoted prefix value with a space)' '```bash
IFS=" " read -r x < f
echo "$x"
```'
lint_clean 'LC_ALL=C declare -i n=0 (prefix before a DECLARATION)' '```bash
LC_ALL=C declare -i n=0
echo "$n"
```'
lint_clean "IFS=\$' \\t' read -r a b (ANSI-C quoted prefix with whitespace)" '```bash
IFS=$'"'"' \t'"'"' read -r a b < f
echo "$a $b"
```'
lint_clean 'two prefixes at once, one of them quoted' '```bash
LC_ALL=C IFS=" " read -r a < f
echo "$a"
```'
lint_clean "the prefix's OWN name stays bound (LC_ALL, not just n)" '```bash
LC_ALL=C declare -i n=0
echo "$LC_ALL $n"
```'

# ============================================================
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
