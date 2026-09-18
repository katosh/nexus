#!/usr/bin/env bash
# test-public-mirror-symlink-target.sh — the public mirror's leak gate must be
# able to READ every byte `git write-tree` would publish, not merely every byte
# `git grep` happens to open.
#
# THE HOLE THIS FILLS (your-org/nexus-code#1294). A tracked SYMLINK's blob
# content IS its target path, and `git write-tree` publishes that blob VERBATIM.
# Neither `git grep` nor `git grep --cached` reads it. Three independently
# defensible choices lined up to produce a silent pass:
#
#   - build.sh SKIPS symlinks — correctly, because `scrub_one < "$f" > "$f"` on
#     a symlink reads and TRUNCATES the target file;
#   - leak-gate.sh's PATH check reads only the link's own NAME;
#   - `git grep` does not read symlink content at all.
#
# So a link to `../<denied>/secret/path.txt` passed the gate clean, printed
# "PASS — zero denied tokens", and the published blob still carried the denied
# path. On a PUBLISHED PUBLIC MIRROR that failure is permanent once it occurs.
#
# WHAT THIS ASSERTS. Both halves of the repair, driven against the REAL,
# UNMODIFIED production scripts with a SYNTHETIC dictionary and a SYNTHETIC
# target path — no internal identifier appears in this file or in any fixture
# it builds:
#
#   A. leak-gate.sh FAILS (rc 1) on a denied token in a symlink TARGET, and
#      names the link. This is the POTENCY CONTROL: it builds the offending
#      input, RUNS the gate, and observes the verdict FLIP.
#   B. leak-gate.sh still PASSES (rc 0) on a clean symlink — so A is not an
#      always-fail.
#   C. leak-gate.sh REFUSES (rc 6) an index entry whose mode it cannot read
#      (a gitlink). This is the DEFAULT-DENY arm: the class fix is keyed on the
#      PROPERTY "can this gate read the bytes this entry publishes?", so the
#      next object type git learns to record is a refusal, not a silent pass.
#   D. leak-gate.sh FAILS on a denied token inside a BINARY regular file.
#      Measured: without `-I`, git grep reports "Binary file X matches" and the
#      gate catches it; WITH `-I` it returns nothing and the gate goes green.
#      This arm exists so that adding `-I` to that git grep is a RED, not a
#      silent re-opening of the same class one file type over.
#   E. build.sh rewrites a symlink's TARGET and does NOT write through the
#      link — the target file's bytes are byte-identical afterwards.
#   F. The same for a symlink that RESOLVES TO A DIRECTORY. Added because the
#      mutant `ln -sfn` -> `ln -sf` SURVIVED arms A-E: every fixture there
#      linked to a FILE, and `-n` only matters for a directory. The guard was
#      fitted to the shape of the finding; F is the input that separates the
#      guard from the fixture it was written against.
#
# ANTI-VACUITY. Every arm above runs the real script and asserts a specific
# rc AND a specific string; a fixture that failed to build is a FAIL, never a
# skip; and the assertion total is pinned below, so a branch that silently
# stopped running is itself a failure rather than a smaller number nobody
# reads. This suite is a fix for "a guard reports green when it did not run" —
# it must not become one.
#
# Run: bash monitor/watcher/test-public-mirror-symlink-target.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
GATE="$SRC_ROOT/monitor/public-mirror/leak-gate.sh"
BUILD="$SRC_ROOT/monitor/public-mirror/build.sh"

PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$1"; _th_pass; }
fail(){ printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

[ -x "$GATE" ]  || { echo "missing $GATE" >&2; exit 1; }
[ -r "$BUILD" ] || { echo "missing $BUILD" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pmsym.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
cleanup(){ [ -n "${WORK:-}" ] && rm -rf -- "$WORK"; }
trap cleanup EXIT

# --- SYNTHETIC dictionary. `zarquon` is a nonsense token that appears in no
# real mapping; the dictionary lives OUTSIDE every fixture repo so it is never
# itself a hit. No internal identifier is used anywhere in this suite.
MAP="$WORK/synthetic-map.tsv"
{
  printf 'map\tzarquon\tpublicword\t<publicword>\n'
  printf 'deny\tzarquon\n'
} > "$MAP"

# mkrepo <dir> — a fixture git repo that is its OWN root. Verified, because
# `git init` failing silently would leave every later probe answering about an
# ENCLOSING repository at rc 0 (CLAUDE.md: git -C walks UP).
mkrepo(){
  local d=$1
  rm -rf -- "$d"; mkdir -p "$d" || return 1
  ( cd "$d" \
      && git init -q . \
      && git config --local user.email fixture@example.invalid \
      && git config --local user.name  fixture ) || return 1
  local top real
  top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || return 1
  real=$(cd "$d" && pwd -P) || return 1
  [ "$top" = "$real" ] || return 1
  return 0
}

# run_gate <dir> -> sets GRC and GOUT. rc captured BEFORE any pipe.
run_gate(){
  GOUT=$(bash "$GATE" "$MAP" "$1" 2>&1); GRC=$?
  return 0
}

# ---------------------------------------------------------------- A + B ----
# A tracked symlink whose TARGET carries the denied token. The link's own NAME
# is clean, so the PATH check cannot see it; the target FILE does not exist, so
# there is nothing for a content scan to follow even if it tried.

if mkrepo "$WORK/a"; then
  ( cd "$WORK/a" \
      && echo 'ordinary content' > plain.txt \
      && ln -s ../zarquon/secret/path.txt link.txt \
      && git add -A && git commit -q -m fixture ) >/dev/null 2>&1
  # Prove the fixture is the shape the finding describes before believing any
  # verdict about it: exactly one mode-120000 entry, and its blob really does
  # carry the token.
  _modes=$(git -C "$WORK/a" ls-files -s | awk '$1=="120000"' | wc -l)
  _sha=$(git -C "$WORK/a" ls-files -s | awk '$1=="120000"{print $2}')
  _blob=$(git -C "$WORK/a" cat-file blob "$_sha" 2>/dev/null)
  if [ "$_modes" = "1" ] && grep -qi 'zarquon' <<<"$_blob"; then
    pass "fixture A is well-formed: 1 tracked symlink whose published blob carries the denied token"
  else
    fail "fixture A malformed (120000 entries=$_modes, blob=$_blob) — every verdict below would be meaningless"
  fi

  run_gate "$WORK/a"
  if [ "$GRC" -eq 1 ]; then
    pass "A: leak-gate REFUSES a denied token in a symlink TARGET (rc 1)"
  else
    fail "A: leak-gate rc=$GRC (want 1) — a denied symlink target passed the gate. Output: $GOUT"
  fi
  if grep -q 'SYMLINK TARGET' <<<"$GOUT" && grep -q 'link.txt' <<<"$GOUT"; then
    pass "A: the failure NAMES the offending link and the surface"
  else
    fail "A: failure text does not name the link/surface: $GOUT"
  fi
else
  fail "A: fixture repo could not be built"
  fail "A: fixture repo could not be built (rc arm)"
  fail "A: fixture repo could not be built (message arm)"
fi

if mkrepo "$WORK/b"; then
  ( cd "$WORK/b" \
      && echo 'ordinary content' > plain.txt \
      && ln -s ../harmless/ordinary/path.txt link.txt \
      && git add -A && git commit -q -m fixture ) >/dev/null 2>&1
  run_gate "$WORK/b"
  if [ "$GRC" -eq 0 ]; then
    pass "B: a CLEAN symlink target still passes (rc 0) — A is not an always-fail"
  else
    fail "B: clean symlink rejected, rc=$GRC. Output: $GOUT"
  fi
else
  fail "B: fixture repo could not be built"
fi

# -------------------------------------------------------------------- C ----
# DEFAULT-DENY. A gitlink's content is not in this tree at all, so the gate
# cannot vouch for it and must REFUSE rather than pass. This arm is the class
# fix: it fires for any mode the allowlist does not name, including modes that
# do not exist yet.

# The inner repo must live AT c/sub. A gitlink with no working-tree
# counterpart makes `git diff` (index vs worktree) dirty, and the gate's
# exit-5 refusal fires FIRST — a different arm, and arm C would then be
# asserting nothing about mode handling at all.
if mkrepo "$WORK/c" && mkrepo "$WORK/c/sub"; then
  ( cd "$WORK/c/sub" && echo x > f && git add -A && git commit -q -m inner ) >/dev/null 2>&1
  ( cd "$WORK/c" && echo ok > plain.txt && git add -A && git commit -q -m fixture ) >/dev/null 2>&1
  _isha=$(git -C "$WORK/c/sub" rev-parse HEAD 2>/dev/null)
  git -C "$WORK/c" update-index --add --cacheinfo "160000,$_isha,sub" >/dev/null 2>&1
  _gl=$(git -C "$WORK/c" ls-files -s | awk '$1=="160000"' | wc -l)
  if [ "$_gl" = "1" ]; then
    pass "fixture C is well-formed: exactly 1 gitlink entry in the index"
  else
    fail "fixture C malformed: $_gl gitlink entries (want 1)"
  fi
  run_gate "$WORK/c"
  if [ "$GRC" -eq 6 ]; then
    pass "C: leak-gate REFUSES (rc 6) an index entry whose published content it cannot read"
  else
    fail "C: leak-gate rc=$GRC (want 6) on a gitlink. Output: $GOUT"
  fi
  if grep -q 'REFUSED' <<<"$GOUT" && grep -q '160000' <<<"$GOUT"; then
    pass "C: the refusal NAMES the unreadable mode"
  else
    fail "C: refusal does not name the mode: $GOUT"
  fi
else
  fail "C: fixture repos could not be built"
  fail "C: fixture repos could not be built (rc arm)"
  fail "C: fixture repos could not be built (message arm)"
fi

# -------------------------------------------------------------------- D ----
# The adjacent member of the same class, pinned so it cannot be re-opened.
# Measured on this host: `git grep -inE PAT` on a NUL-bearing file prints
# "Binary file X matches" at rc 0, so the gate catches it — but `git grep -I`
# returns rc 1 and NOTHING. Adding `-I` to the gate's content scan would blind
# it to every binary file, silently.

if mkrepo "$WORK/d"; then
  printf 'pre\000zarquon\000post\n' > "$WORK/d/blob.dat"
  ( cd "$WORK/d" && git add -A && git commit -q -m fixture ) >/dev/null 2>&1
  # Prove the fixture really is binary to git, or arm D asserts nothing.
  if git -C "$WORK/d" grep -I -inE 'zarquon' >/dev/null 2>&1; then
    fail "fixture D is not binary to git — arm D would prove nothing"
  else
    pass "fixture D is well-formed: git treats blob.dat as BINARY (git grep -I finds nothing)"
  fi
  run_gate "$WORK/d"
  if [ "$GRC" -eq 1 ]; then
    pass "D: leak-gate FAILS on a denied token inside a BINARY file (so no \`-I\` on the content scan)"
  else
    fail "D: leak-gate rc=$GRC (want 1) on a binary file carrying the token. Output: $GOUT"
  fi
else
  fail "D: fixture repo could not be built"
  fail "D: fixture repo could not be built (rc arm)"
fi

# -------------------------------------------------------------------- E ----
# build.sh must scrub the symlink TARGET by rewriting the LINK, and must NOT
# write through it. The fixture is a throwaway repo built by this suite, which
# is what build.sh's own entry guard (#1001) exists to make safe: it refuses a
# dirty tree and refuses to act without --yes. We assert the root it will act
# on BEFORE invoking it, so a mis-built fixture can never point it elsewhere.

if mkrepo "$WORK/e"; then
  ( cd "$WORK/e" \
      && mkdir -p real \
      && printf 'TARGET BYTES MUST NOT CHANGE\n' > real/target.txt \
      && ln -s ../real/target.txt pointer.txt \
      && mkdir -p d && ln -s ../zarquon/elsewhere.txt d/deep.txt \
      && echo 'plain' > plain.txt \
      && git add -A && git commit -q -m fixture ) >/dev/null 2>&1
  _before_target=$(md5sum "$WORK/e/real/target.txt" 2>/dev/null | awk '{print $1}')
  _etop=$(cd "$WORK/e" && git rev-parse --show-toplevel 2>/dev/null)
  _ereal=$(cd "$WORK/e" && pwd -P)
  if [ -n "$_etop" ] && [ "$_etop" = "$_ereal" ]; then
    pass "E: build.sh's target root resolves to the throwaway fixture, not to any real checkout"
    mkdir -p "$WORK/tool/overlay"
    cp -- "$BUILD" "$WORK/tool/build.sh"
    cp -- "$SRC_ROOT/monitor/public-mirror/scrub.pl" "$WORK/tool/scrub.pl"
    if cmp -s "$BUILD" "$WORK/tool/build.sh"; then
      pass "E: the build.sh under test is byte-identical to the tracked one"
    else
      fail "E: the copied build.sh differs from the tracked one — this arm would test a different script"
    fi
    BOUT=$( cd "$WORK/e" && bash "$WORK/tool/build.sh" "$MAP" --yes 2>&1 ); BRC=$?
    _after_link=$(readlink -- "$WORK/e/d/deep.txt" 2>/dev/null)
    _after_target=$(md5sum "$WORK/e/real/target.txt" 2>/dev/null | awk '{print $1}')
    if [ "$BRC" -eq 0 ]; then
      pass "E: build.sh completed on the fixture (rc 0)"
    else
      fail "E: build.sh rc=$BRC. Output: $BOUT"
    fi
    if [ -n "$_after_link" ] && ! grep -qi 'zarquon' <<<"$_after_link"; then
      pass "E: the symlink TARGET was scrubbed (now '$_after_link')"
    else
      fail "E: symlink target still carries the denied token: '$_after_link'"
    fi
    if [ -L "$WORK/e/d/deep.txt" ]; then
      pass "E: the entry is still a SYMLINK (rewritten, not replaced by a regular file)"
    else
      fail "E: d/deep.txt is no longer a symlink — the link was dereferenced"
    fi
    if [ -n "$_before_target" ] && [ "$_before_target" = "$_after_target" ]; then
      pass "E: the pointed-to TARGET FILE is byte-identical — build.sh did not write through the link"
    else
      fail "E: target file changed ($_before_target -> $_after_target) — build.sh wrote THROUGH the symlink"
    fi
  else
    fail "E: fixture root did not resolve to itself — REFUSING to invoke build.sh"
    fail "E: skipped (root guard)"; fail "E: skipped (root guard)"
    fail "E: skipped (root guard)"; fail "E: skipped (root guard)"
    fail "E: skipped (root guard)"
  fi
else
  fail "E: fixture repo could not be built"
  fail "E: fixture repo could not be built"; fail "E: fixture repo could not be built"
  fail "E: fixture repo could not be built"; fail "E: fixture repo could not be built"
  fail "E: fixture repo could not be built"
fi

# -------------------------------------------------------------------- F ----
# `-n` in `ln -sfn` is load-bearing and ONLY for a link that points at a
# DIRECTORY: without it, `ln -sf` FOLLOWS the existing link and creates the new
# one INSIDE the target directory, leaving the original link — and its denied
# token — exactly where it was, while `ln` exits 0.
#
# This arm exists because the mutant `ln -sfn` -> `ln -sf` SURVIVED arms A-E:
# every fixture there linked to a FILE, so the guard was fitted to the shape of
# the finding rather than to the property. A link to a directory is the input
# that separates them.

if mkrepo "$WORK/f"; then
  ( cd "$WORK/f" \
      && mkdir -p real/zarquon_sub \
      && echo 'inner' > real/zarquon_sub/inner.txt \
      && ln -s real/zarquon_sub linkdir \
      && git add -A && git commit -q -m fixture ) >/dev/null 2>&1
  _fmode=$(git -C "$WORK/f" ls-files -s -- linkdir | awk '{print $1}')
  if [ "$_fmode" = "120000" ] && [ -d "$WORK/f/linkdir/" ]; then
    pass "fixture F is well-formed: a tracked symlink that RESOLVES TO A DIRECTORY"
  else
    fail "fixture F malformed (mode=$_fmode, resolves-to-dir=$([ -d "$WORK/f/linkdir/" ] && echo yes || echo no))"
  fi
  mkdir -p "$WORK/toolf/overlay"
  cp -- "$BUILD" "$WORK/toolf/build.sh"
  cp -- "$SRC_ROOT/monitor/public-mirror/scrub.pl" "$WORK/toolf/scrub.pl"
  _ftop=$(cd "$WORK/f" && git rev-parse --show-toplevel 2>/dev/null)
  _freal=$(cd "$WORK/f" && pwd -P)
  if [ -n "$_ftop" ] && [ "$_ftop" = "$_freal" ]; then
    FOUT=$( cd "$WORK/f" && bash "$WORK/toolf/build.sh" "$MAP" --yes 2>&1 ); FRC=$?
    _flink=$(readlink -- "$WORK/f/linkdir" 2>/dev/null)
    if [ -n "$_flink" ] && ! grep -qi 'zarquon' <<<"$_flink"; then
      pass "F: a directory-pointing symlink's target was scrubbed in place (now '$_flink')"
    else
      fail "F: directory-pointing symlink still carries the denied token: '$_flink' (rc=$FRC) — \`ln\` followed the link instead of replacing it"
    fi
    # The stray link `ln -sf` would leave behind INSIDE the target directory.
    if [ ! -e "$WORK/f/real/zarquon_sub/publicword_sub" ] && [ ! -L "$WORK/f/real/zarquon_sub/publicword_sub" ]; then
      pass "F: no stray link was created inside the target directory"
    else
      fail "F: a stray link was created inside the target directory — the link was dereferenced"
    fi
  else
    fail "F: fixture root did not resolve to itself — REFUSING to invoke build.sh"
    fail "F: skipped (root guard)"
  fi
else
  fail "F: fixture repo could not be built"
  fail "F: fixture repo could not be built"
  fail "F: fixture repo could not be built"
fi

# -------------------------------------------------------------------- G ----
# THE KEEP LIST MUST APPLY TO SYMLINK TARGETS TOO (your-org/nexus-code#1294,
# reopened).
#
# `leak-gate.sh` filters `sym_hits` through `$KEEP` exactly as it does the
# content and path hits. Nothing exercised it: DELETE that line and every
# leak-gate suite on this branch still passed — measured 19/0 on this file,
# with the dictionary-coverage and build-entry-guard suites green alongside.
# No fixture anywhere planted a `keep` mapping against a symlink, so the line
# was correct and unwatched.
#
# WHY AN UNWATCHED SAFE-DIRECTION LINE IS WORTH A TEST. Losing it fails toward
# a FALSE REFUSAL on the publish path — the operator's own kept public assets
# start failing the gate. That is the failure nobody fixes, because a refusing
# gate looks like a working gate, and the pressure it creates is pressure to
# disable it. The other three arms of this suite all pin the DENY direction;
# this is the only one that pins the EXEMPTION.
#
# This arm was ported from a parallel branch that was dropped as redundant on
# an assertion-count comparison (19 vs 11). The count was the wrong instrument:
# it establishes that one suite asserts MORE, never that it asserts a SUPERSET.
# The right check for a drop is the mutant, and this is the mutant that
# survived here and was killed there.
G_OK=0
if mkrepo "$WORK/g"; then
  # A SECOND dictionary: same deny token, plus a keep pattern that exempts one
  # specific public asset whose name legitimately contains it.
  MAPK="$WORK/synthetic-map-keep.tsv"
  {
    printf 'map\tzarquon\tpublicword\t<publicword>\n'
    printf 'deny\tzarquon\n'
    printf 'keep\tzarquon-public-asset\n'
  } > "$MAPK"

  mkdir -p "$WORK/g/sub"
  printf 'ordinary content\n' > "$WORK/g/sub/plain.txt"
  ln -sfn ../zarquon-public-asset/readme.md "$WORK/g/sub/kept-link.md"
  ( cd "$WORK/g" && git add -A >/dev/null 2>&1 && git commit -qm g >/dev/null 2>&1 )

  # POSITIVE CONTROL FIRST: without the keep line in the dictionary, this very
  # fixture MUST fail. Otherwise a green below could mean "the keep list
  # worked" or "the target never matched the denylist at all", and those are
  # different facts.
  GOUT=$(bash "$GATE" "$MAP" "$WORK/g" 2>&1); GRC=$?
  if (( GRC == 1 )); then
    pass "G control: the same symlink target FAILS when nothing exempts it"
  else
    fail "G control: expected rc 1 without a keep pattern, got $GRC — the fixture does not reach the deny path (out: $GOUT)"
  fi

  GOUT=$(bash "$GATE" "$MAPK" "$WORK/g" 2>&1); GRC=$?
  if (( GRC == 0 )); then
    pass "G: a KEEP-listed symlink target is exempt — the keep list reaches sym_hits"
  else
    fail "G: expected rc 0 for a keep-listed symlink target, got $GRC (out: $GOUT)"
  fi
  G_OK=1
fi
if (( G_OK == 0 )); then
  fail "G: fixture repo could not be built"
  fail "G: fixture repo could not be built"
fi

# -------------------------------------------------------------------- H ----
# THE NON-GIT TREE (your-org/nexus-code#1294, reopened — second finding).
#
# Both the PATH check and the CONTENT check fall back to `find`/`grep -r` when
# there is no index, because a hand-assembled tree is a SUPPORTED mode of this
# gate. The symlink check had no such arm, so in exactly that mode the gate
# scanned file NAMES and file CONTENTS and silently skipped symlink TARGETS —
# #1294's hole surviving inside #1294's own fix, in the one mode nobody tested.
#
# Latent: no in-tree caller runs the gate outside a git checkout today. Pinned
# anyway, because the asymmetry between three checks in one file is not a
# decision anyone made, and its direction is a silently smaller population
# under a clean verdict.
H_OK=0
H_TREE="$WORK/h/tree"
rm -rf -- "$WORK/h"; mkdir -p "$H_TREE/sub"
printf 'ordinary content\n' > "$H_TREE/sub/plain.txt"
if ln -sfn ../zarquon/secret/path.txt "$H_TREE/sub/link.txt" 2>/dev/null; then
  # NON-VACUITY: it must really NOT be a git tree, or this measures the index
  # path and says nothing about the fallback. `git rev-parse` WALKS UP, so ask
  # from inside the fixture exactly as the gate does.
  if ( cd "$H_TREE" && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ); then
    fail "H fixture: the tree is INSIDE a git work tree, so the non-git arm is unreachable here"
    fail "H fixture: (see above)"
  else
    pass "H fixture: the tree is genuinely NOT a git checkout, so the fallback arm is the one under test"
    GOUT=$( cd "$H_TREE" && bash "$GATE" "$MAP" . 2>&1 ); GRC=$?
    # Herestring, NOT `printf … | grep -qF`: an early-exiting `grep -q`
    # SIGPIPEs its producer, so under `pipefail` the pipeline reports 141 —
    # a FALSE failure on a string that DOES match. Flagged by
    # test-sigpipe-assertion-lint.sh, which guards-for-diff selected because
    # this file joined its construct-keyed population. Second time this bit me
    # on this branch; the herestring is the prescribed form.
    if (( GRC == 1 )) && grep -qF 'SYMLINK TARGET' <<<"$GOUT"; then
      pass "H: a leaking symlink target is caught in a NON-GIT tree too"
    else
      fail "H: expected rc 1 naming the symlink target in a non-git tree, got $GRC (out: $GOUT)"
    fi
  fi
  H_OK=1
fi
if (( H_OK == 0 )); then
  fail "H: fixture could not be built"
  fail "H: fixture could not be built"
fi

# --- assertion-count guard ------------------------------------------------
#
# A VERDICT IS NOT A COUNT. This suite exists because a gate printed a green
# verdict over a population it could not see; a suite that silently stopped
# running arms would do exactly the same thing one level up. Pin the total.
#
# 3 (A) + 1 (B) + 3 (C) + 2 (D) + 6 (E) + 3 (F) + 2 (G) + 2 (H) + this one = 23.
# G's two: the no-keep positive control, and the keep-listed exemption.
# H's two: the not-a-git-tree non-vacuity check, and the fallback catch.
# E's six: root guard, byte-identity of the copied build.sh, rc, target
# scrubbed, still a symlink, target file unchanged.
# F's three: fixture shape, target scrubbed, no stray link.
EXPECTED_ASSERTIONS=23
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} + 1 ))
if (( TOTAL_ASSERTIONS == EXPECTED_ASSERTIONS )); then
    pass "assertion total is exactly $EXPECTED_ASSERTIONS — no arm was silently skipped"
else
    fail "assertion total $TOTAL_ASSERTIONS != expected $EXPECTED_ASSERTIONS — an arm ran short or was skipped"
fi

th_summary_and_exit
