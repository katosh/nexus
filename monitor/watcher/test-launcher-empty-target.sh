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
#
# A/B/C/E/F/G all FAIL on pre-fix source. D and H pass in both directions, by
# design — they are the no-regression half.
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
lint=$(python3 - "$GUIDE" <<'PY'
import re, subprocess, sys
path = sys.argv[1]
lines = open(path).read().split('\n')

# Ambient: exported into every nexus shell, so a bare reference is legitimate.
AMBIENT = {'NEXUS_ROOT', 'HOME', 'PATH', 'USER', 'PWD'}

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
    assigned = set(re.findall(r'^\s*(?:export\s+|local\s+)?([A-Za-z_]\w*)=', body, re.M))
    assigned |= set(re.findall(r'\bfor\s+([A-Za-z_]\w*)\s+in\b', body))
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
)
assert_eq "F/H: GUIDE.md snippets are self-contained and parse" "$lint" ""

# ============================================================
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
