#!/usr/bin/env bash
# Lint: no shell source in this repo may build a `<ref>:<path>` argument as
# `"$var:literal"` (your-org/nexus-code#568 A10).
#
# THE DEFECT. In zsh, `$var:x` applies a HISTORY-STYLE MODIFIER to the
# parameter, and double quotes do not protect you. When the character after the
# colon is a literal modifier letter, zsh consumes it:
#
#   b=main
#   print -r -- "$b:audit/f"     # → <cwd>/mainudit/f   (:a = absolute path)
#   print -r -- "$b:results/f"   # → mainesults/f       (:r = remove extension)
#   print -r -- "$b:tests/f"     # → mainests/f         (:t = tail)
#   print -r -- "$b:src/f"       # → zsh: bad substitution (exit 1)
#   print -r -- "${b}:audit/f"   # → main:audit/f       CORRECT
#
# Two failure modes, and the dangerous one is the first: a silently WRONG but
# plausible path. It fires only on a LITERAL modifier letter directly after
# `$var:` — `"$b:$p/f"` is safe — which is why it survives casual testing and
# ambushes exactly the call site that hardcodes a directory name. Common repo
# directory names collide: audit/ results/ tests/ src/ experiments/ hooks/
# lib/ config/ utils/.
#
# WHY A LINT AND NOT A NOTE. This workspace is zsh-default, so every agent is
# exposed, and the idiom it corrupts is the one this workspace PRESCRIBES:
# after `git rev-parse <ref>:<path>` was found to pollute stdout, the remedy
# issued was `git cat-file -e <ref>:<path>` — precisely what this breaks. The
# discovering worker's account is what makes it a different severity class from
# the other zsh traps: "that one fabricated evidence against someone else's
# correct claim, and only `ls-tree` disagreeing caught it." A tool that
# manufactures false negatives against a colleague's correct assertion cannot
# be left to a documentation note alone.
#
# Run: bash monitor/watcher/test-zsh-modifier-lint.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

# --- 1. the trap is real (executable proof, not prose) ---------------------
# Assert the behaviour against a real zsh so this file documents a fact that
# still holds, rather than folklore. Skips cleanly where zsh is absent.
if command -v zsh >/dev/null 2>&1; then
    got=$(zsh -c 'b=main; print -r -- "$b:tests/f"' 2>&1)
    if [[ "$got" == "mainests/f" ]]; then
        ok "zsh really does eat the modifier: \"\$b:tests/f\" → $got"
    else
        bad "modifier premise" "expected 'mainests/f', got '$got' — zsh behaviour changed; revisit this lint"
    fi
    got=$(zsh -c 'b=main; print -r -- "${b}:tests/f"' 2>&1)
    if [[ "$got" == "main:tests/f" ]]; then
        ok "bracing is the fix: \"\${b}:tests/f\" → $got"
    else
        bad "bracing fix" "expected 'main:tests/f', got '$got'"
    fi
else
    echo "  (skip: zsh not available — premise assertions unexercised)"
fi

# --- 2. no source in the repo carries the hazardous form -------------------
# The pattern: a `$name:` immediately followed by a zsh modifier letter. zsh's
# modifiers are a c e g h l p q r s t u x A (plus & and #); restrict to the ones
# that can begin a plausible directory name so the lint has no false positives
# on `$url:/path` or `$PATH:/usr/bin` (the character after the colon there is
# `/`, which is not a modifier).
#
# `git ls-files` scopes this to TRACKED sources only — no recursive `find .`,
# and no sweep of work/ or of an operator's untracked scratch files.
#
# THIS FILE EXCLUDES ITSELF, and that is not a loophole. A lint for a textual
# pattern must contain that pattern — in the worked examples above, and in the
# positive control below that proves the matcher still matches. Scanning itself
# would make it permanently, uninformatively red. The anti-vacuous guard in
# section 3 is what keeps the exclusion honest: the pattern is still proven to
# fire, just against a fixture instead of against this file's own prose.
#
# OTHER FILES THAT MUST CARRY THE PATTERN EXEMPT BY MARKER, NOT BY FILENAME
# (your-org/nexus-code#804). The self-exclusion above is a filename allowlist of
# exactly one, and it stops working the moment a SECOND file legitimately needs
# the literal — which `#804` produced: `test-claude-md-ancestor-timeline.sh`
# executes the trap against a fixture to prove the CLAUDE.md entry still holds,
# so the hazardous form is its subject matter. Widening the filename list is the
# erosion this repo warns about elsewhere (`th_strip_heredocs`: "EXEMPT BY
# MARKER, NOT BY FILENAME … applied to a scanner's own file, blinds the one file
# best able to hide a violation"). So a line may exempt ITSELF, in place, by
# carrying
#
#     zsh-modifier-lint: allow-demonstration  <why this line must be literal>
#
# A REASON IS MANDATORY. The marker alone does not exempt — section 3 asserts
# that a reasonless marker is still reported — because a bare mute is just a
# filename allowlist with extra steps, and the reason is what a future reader
# needs in order to judge whether the exemption is still earned.
# The reason must be >= 8 characters of actual text. `[^[:space:]].{7,}` — a
# non-space first character, then seven more of ANYTHING: reasons are prose and
# contain spaces. A first draft wrote `[^[:space:]]{8,}`, requiring eight
# CONTIGUOUS non-space characters, which rejected every multi-word reason and
# so exempted nothing while looking like it worked. Section 4 catches that: it
# feeds a real multi-word reason through and requires it to be exempted.
_LINT_MARKER='zsh-modifier-lint:[[:space:]]+allow-demonstration[[:space:]]+[^[:space:]].{7,}'
_self="monitor/watcher/$(basename "${BASH_SOURCE[0]}")"
mapfile -t sources < <(
    cd "$REPO_ROOT" && git ls-files -z -- '*.sh' 'monitor/ng' 'monitor/*/gh' \
        'monitor/*/pip' 'monitor/*/sandbox-notify' 'monitor/shellenv/*' 2>/dev/null \
        | tr '\0' '\n' | grep -v '^$' | grep -vFx "$_self"
)
if (( ${#sources[@]} == 0 )); then
    bad "source enumeration" "git ls-files returned nothing — lint would vacuously pass"
else
    ok "enumerated ${#sources[@]} tracked shell sources"
    hits=$(cd "$REPO_ROOT" && grep -nE '\$[A-Za-z_][A-Za-z0-9_]*:[acegHhlpqrstuxA][A-Za-z0-9_.-]*/' \
              -- "${sources[@]}" 2>/dev/null | grep -v '\${' \
              | grep -vE "$_LINT_MARKER" || true)
    if [[ -z "$hits" ]]; then
        ok "no source builds a <ref>:<path> argument as \"\$var:literal\" (brace it: \"\${var}:\${path}\")"
    else
        bad "hazardous unbraced \$var:<modifier> form" "$(printf '\n%s' "$hits")"
    fi
fi

# --- 3. the lint can actually catch one (anti-vacuous guard) ---------------
# A lint that cannot fail is not a lint. Feed it a known-bad line and assert
# the pattern matches, so a future regex edit that silently stops matching is
# itself caught.
probe=$(mktemp); trap 'rm -f "$probe"' EXIT
printf 'git cat-file -e "$ref:tests/fixture.txt" || exit 1\n' > "$probe"
if grep -qE '\$[A-Za-z_][A-Za-z0-9_]*:[acegHhlpqrstuxA][A-Za-z0-9_.-]*/' "$probe"; then
    ok "the lint pattern matches a known-bad line (not vacuous)"
else
    bad "anti-vacuous guard" "pattern failed to match the deliberate positive control"
fi
# …and does NOT match the safe forms, so it stays usable.
printf 'PATH="$bin:/usr/bin:/bin"\nurl="$scheme://127.0.0.1:$port/lab"\ngit show "${ref}:${path}"\n' > "$probe"
if grep -qE '\$[A-Za-z_][A-Za-z0-9_]*:[acegHhlpqrstuxA][A-Za-z0-9_.-]*/' "$probe"; then
    bad "false-positive guard" "pattern matched a SAFE line (PATH concat / URL / braced ref)"
else
    ok "the lint pattern does not match safe \$var:/path, URL, or braced forms"
fi

# --- 4. the MARKER exemption behaves, in BOTH directions -------------------
# your-org/nexus-code#804. Asserted as a pair, deliberately: a mechanism that
# only ever exempts is indistinguishable from deleting the check, and this one
# guards a lint whose whole job is to catch a silent wrong answer.
_marker_filter() {   # stdin: raw grep hits → stdout: what the lint would report
    grep -vE "$_LINT_MARKER" || true
}
# (a) marker WITH a reason is exempted…
exempted=$(printf '%s\n' \
    'f.sh:9:    z=$(zsh -c "print -r -- \"$b:tests/f\"")   # zsh-modifier-lint: allow-demonstration  executes the trap to prove CLAUDE.md still holds' \
    | _marker_filter)
if [[ -z "$exempted" ]]; then
    ok "a line carrying the marker WITH a reason is exempted"
else
    bad "marker exemption" "a properly-marked line was still reported: $exempted"
fi
# (b) …and a REASONLESS marker is NOT. This is the load-bearing half: without
#     it the marker degrades into a bare mute anyone can paste in.
for _bare in 'f.sh:9:    z="$b:tests/f"   # zsh-modifier-lint: allow-demonstration' \
             'f.sh:9:    z="$b:tests/f"   # zsh-modifier-lint: allow-demonstration  short'; do
    still=$(printf '%s\n' "$_bare" | _marker_filter)
    if [[ -n "$still" ]]; then
        ok "a marker with no usable reason is still reported ($(printf '%s' "${_bare##*allow-demonstration}" | tr -d ' ' | head -c 12 || true)…)"
    else
        bad "reasonless marker" "the marker muted a line without giving a reason: $_bare"
    fi
done
# (c) the marker does not mute a NEIGHBOURING violation on another line.
neighbour=$(printf '%s\n%s\n' \
    'f.sh:9:  ok="$b:tests/f"  # zsh-modifier-lint: allow-demonstration  the documented demonstration' \
    'g.sh:4:  bad="$b:results/real.txt"' \
    | _marker_filter)
if [[ "$neighbour" == *'g.sh:4'* && "$neighbour" != *'f.sh:9'* ]]; then
    ok "the marker exempts only its own line, not its neighbours"
else
    bad "marker scope" "expected only g.sh:4 to survive the filter, got: $neighbour"
fi

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
echo "FAILED" >&2; exit 1
