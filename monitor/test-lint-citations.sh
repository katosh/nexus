#!/usr/bin/env bash
# Tests for monitor/lint-citations.py — the citation rail gate that rejects a
# line number which does not pin its tree (your-org/your-nexus#263, root cause:
# a comment pinned a SHA for the code and cited line numbers from a different
# tree; on `main` one of them landed on a red reviewer note).
#
# Run: bash monitor/test-lint-citations.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# The contract under test:
#   VIOLATION (exit 1): a bare `Lnnn` in prose; a `file.ext:123` citation;
#                       a `/blob/<branch>/…#Lnnn` permalink (looks pinned, is not).
#   CLEAN     (exit 0): `Lnnn` inside `/blob/<40-hex-sha>/…#Lnnn`.
#   --loose   tolerates a bare `Lnnn` only when the SAME sentence names a tree.
#
# A lint that has never failed has never been tested: every assertion below that
# expects exit 1 is the lint being watched to fail on a defect planted on purpose.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/lint-citations.py"
PY="${PYTHON:-python3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

check() {  # check <name> <expected-exit> <file> [flags...]
  local name="$1" want="$2" file="$3"; shift 3
  "$PY" "$LINT" "$@" "$file" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    printf '  ok   %-52s (exit %d)\n' "$name" "$got"; pass=$((pass + 1))
  else
    printf '  FAIL %-52s (want exit %d, got %d)\n' "$name" "$want" "$got"; fail=$((fail + 1))
  fi
}

SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

printf 'The claim sits at L121 of the manuscript.\n' > "$TMP/bare.md"
printf 'See kompot_manuscript.tex:121 for the claim.\n' > "$TMP/colon.md"
printf 'See [`p.py#L5`](https://github.com/o/r/blob/main/p.py#L5).\n' > "$TMP/branch.md"
printf 'Code pinned at e9a5c5a. The manuscript asserts the claim at L121.\n' > "$TMP/founding.md"
printf 'See [`panel.py#L42-L80`](https://github.com/o/r/blob/%s/notebooks/panel.py#L42-L80).\n' "$SHA" > "$TMP/pinned.md"
printf 'On main@e9a5c5a, L403 is a subsection heading.\n' > "$TMP/tree.md"

echo "-- planted defects: the lint MUST fail on each --"
check "bare Lnnn in prose"                       1 "$TMP/bare.md"
check "file.ext:line names no tree"              1 "$TMP/colon.md"
check "branch-pinned permalink (looks pinned)"   1 "$TMP/branch.md"
check "founding defect: SHA one sentence away"   1 "$TMP/founding.md" --loose

printf '```console\n$ printf %s > /tmp/p.md\n  [bare-line-number] L121\n```\nThe claim sits at L121.\n' "'the claim at L121'" > "$TMP/fenceprose.md"
printf '```console\n$ printf %s > /tmp/p.md\n$ lint /tmp/p.md\n  [bare-line-number] L121\n```\n' "'the claim at L121'" > "$TMP/fenced.md"
check "bare Lnnn in prose beside a fence"        1 "$TMP/fenceprose.md"

echo "-- controls: the lint MUST NOT fire --"
check "bare Lnnn inside a fenced transcript"     0 "$TMP/fenced.md"
check "SHA-pinned permalink"                     0 "$TMP/pinned.md"
check "loose: same sentence names the tree"      0 "$TMP/tree.md" --loose

echo "-- the lint's own selftest --"
if "$PY" "$LINT" --selftest >/dev/null 2>&1; then
  printf '  ok   %-52s (exit 0)\n' "--selftest"; pass=$((pass + 1))
else
  printf '  FAIL %-52s\n' "--selftest"; fail=$((fail + 1))
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED ($pass assertions)"
  exit 0
fi
echo "$fail FAILED, $pass passed"
exit 1
