#!/usr/bin/env bash
# build.sh — apply the identifier scrub to the current git checkout in place,
# producing the public-mirror tree. Reproducible + data-driven: all internal
# vocabulary lives in the mapping file, nothing is hardcoded here.
#
#   build.sh [<mapping.tsv>]        (default: alongside this script)
#
# Run it on a clean checkout of the source branch (e.g. `dev`). It:
#   - applies block-level OVERLAY transforms (pre-scrub) from the optional
#     overlay/manifest.tsv, for public rewrites too semantic for line-wise
#     substitution (missing manifest = no-op),
#   - scrubs every tracked file by type (.md/.yml -> angle, else bare),
#   - scrubs tracked symlink TARGETS by rewriting the LINK (never writing
#     through it, which would corrupt the target file),
#   - preserves the executable bit,
#   - drops every `exclude` path from the tree (incl. mapping.tsv itself, so the
#     internal dictionary never ships in the public output).
# Then run leak-gate.sh to prove zero leaks (including over this toolkit's own
# files — the self-scrub check).
set -uo pipefail
export LC_ALL=C
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# ---------------------------------------------------------------------------
# ENTRY GUARD — this script DESTROYS the checkout it is invoked from
# (your-org/nexus-code#1001)
# ---------------------------------------------------------------------------
#
# WHAT HAPPENED. `build.sh` rewrites every tracked file of its cwd IN PLACE and
# `rm -rf`s every `exclude` path. It was run inside a command chain whose
# earlier `cd` had failed — `git clone --local` hit `Invalid cross-device link`
# (the scratchpad is on /tmp, the source on /shared), the `cd` into the
# never-created clone failed, and `zsh` does not abort a `&&`-less chain on a
# failed `cd`. The build then ran in the LIVE WORKING TREE: **513 files
# rewritten**, `mapping.tsv` and `overlay/` deleted. Recovered only because
# nothing was uncommitted.
#
# WHY A GUARD AND NOT A NOTE. The blast radius is the whole tree, the trigger
# is an ordinary shell accident, and the operation NEVER legitimately targets a
# tree anyone cares about — the recipe has always said "run it on a clean
# checkout", i.e. a throwaway. So there is no correct invocation that a refusal
# inconveniences. It is also SELF-CONCEALING in the one way that matters: the
# toolkit's job is redaction and its blast radius includes the redaction
# dictionary, so a build on the wrong tree deletes the file you would use to
# find out what it did. And because the scrub REWRITES rather than reports,
# `git status` afterwards is a wall of legitimate-looking modifications.
#
# THE TWO CHECKS, and what each actually catches:
#
#   * DRY RUN BY DEFAULT (`--yes` / NEXUS_MIRROR_BUILD_OK=1 to act). This is
#     the one that stops the accident AS IT HAPPENED: the command that ran
#     carried no flags, because the documented recipe carried none. Under this
#     change that invocation lands in the live tree and PRINTS what it would
#     do. It exits **6**, never 0 — a caller that forgot the flag must not
#     receive a silent success for work that was not done, which is this
#     corpus's dominant defect class and is not one to reintroduce inside a
#     guard against it.
#
#   * REFUSE A DIRTY TREE (`--allow-dirty` to override). This is the one that
#     covers the catastrophic version. `#1001` was recovered because nothing
#     was uncommitted; on a tree with work in it the loss is total and silent.
#     A correct target is a fresh clone, clean by construction — so a dirty
#     tree is strong evidence the target is wrong. The two suites that build a
#     throwaway clone with the author's uncommitted diff applied on purpose
#     pass `--allow-dirty`, which is the flag saying exactly that.
#
# COVERAGE BOUNDARY, one sentence, on the axis the MECHANISM varies on — WHICH
# TREE THE PROCESS IS STANDING IN: no entry check can distinguish "the tree I
# meant" from "the tree I am in", so these two make the ACCIDENT's shape loud
# (a flagless invocation, and a target with work in it) and leave untouched the
# case of `--yes --allow-dirty` typed deliberately in the wrong clean tree —
# which remains as destructive as it ever was.
#
# NOT DONE, deliberately: `#1001` also suggests refusing when the checkout has
# an upstream. Measured against the five in-tree callers, two of them
# (`test-public-mirror-overlay-drift.sh`, `test-public-mirror-dictionary-
# coverage.sh`) build a plain `git clone`, whose default branch DOES track
# `origin` — so that rule would refuse two legitimate callers and, once they
# were handed an override, would be a flag everybody passes and nobody reads.
# A guard that is always overridden is not a guard.

ASSUME_YES="${NEXUS_MIRROR_BUILD_OK:-0}"
ALLOW_DIRTY=0
_MAP_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)      ASSUME_YES=1; shift ;;
        --dry-run|-n)  ASSUME_YES=0; shift ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        # Explicit, not a line-numbered slice — this file's header has already
        # grown twice in one change, which is exactly how such a slice rots.
        -h|--help)     cat <<'USAGE'; exit 0 ;;
build.sh — apply the identifier scrub to a git checkout IN PLACE.
THIS DESTROYS THE CHECKOUT IT IS INVOKED FROM. Throwaway clones only.
(your-org/nexus-code#1001)

  build.sh [--yes|--dry-run] [--allow-dirty] [<mapping.tsv>]

  --yes, -y        perform the destructive build (or NEXUS_MIRROR_BUILD_OK=1)
  --dry-run, -n    report what it would do and change nothing (THE DEFAULT)
  --allow-dirty    proceed on a tree with uncommitted changes

EXIT CODES
  0  built; run leak-gate.sh next
  2  mapping not readable / unknown flag
  3  an excluded path survived the drop — never ship on this
  4  overlay anchor missing or drifted
  5  a path rename did not take
  6  DRY RUN — nothing was modified, and you did not pass --yes
  7  REFUSED — the working tree has uncommitted changes
  8  REFUSED — cannot establish a git work-tree root (would scrub the caller's cwd)
USAGE
        --) shift; [ $# -gt 0 ] && _MAP_ARG="$1"; break ;;
        -*) echo "build.sh: unknown flag: $1" >&2; exit 2 ;;
        *)  _MAP_ARG="$1"; shift ;;
    esac
done
set -- ${_MAP_ARG:+"$_MAP_ARG"}

MAP="${1:-$_here/mapping.tsv}"
SCRUB="$_here/scrub.pl"
OVERLAY_DIR="$_here/overlay"
OVERLAY_MANIFEST="$OVERLAY_DIR/manifest.tsv"
[ -r "$MAP" ] || { echo "build.sh: mapping not readable: $MAP" >&2; exit 2; }
# ESTABLISH THE TARGET, OR REFUSE. THIS LINE USED TO CARRY #1001'S OWN DEFECT.
#
# It was `root=$(git rev-parse --show-toplevel) && cd "$root"`, under
# `set -uo pipefail` with NO `-e`. Measured: outside a work tree, `rev-parse`
# fails, `root` is ASSIGNED THE EMPTY STRING (so `set -u` never fires), the `&&`
# short-circuits, and THE SCRIPT CARRIES ON IN THE CALLER'S CWD — overlay,
# scrub, exclude-drop and renames all resolving their relative paths against
# whatever directory the caller happened to be in.
#
# That is the incident's exact mechanism living inside the script the incident
# was about: `#1001` was a failed `cd` in the CALLER's chain, and this is a
# failed `cd` in the script's own. Every one of the eight call sites guards its
# own `cd` with `&&` inside a subshell; the script did not guard its own. It
# also sits IMMEDIATELY ABOVE the entry guards below, so a short-circuit here
# would have had them measure and report on the caller's tree while the scrub
# went on to rewrite it — a dry run describing the wrong directory is worse
# than no dry run.
#
# Exit 8: a code nothing in this file or its callers uses (2/3/4/5 are taken,
# 6/7 are the new refusals), so "could not establish a target" never blurs into
# "mapping unreadable" in a caller's error text.
# Found by an independent enumeration of build.sh's call sites.
root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "build.sh: REFUSING — not inside a git work tree, so there is no target to" >&2
    echo "  establish. Continuing here would scrub the caller's cwd ($PWD)." >&2
    echo "  (your-org/nexus-code#1001)" >&2
    exit 8; }
[ -n "$root" ] || {
    echo "build.sh: REFUSING — 'git rev-parse --show-toplevel' succeeded but printed" >&2
    echo "  nothing. An empty target is not a target. (your-org/nexus-code#1001)" >&2
    exit 8; }
cd "$root" || {
    echo "build.sh: REFUSING — cannot cd into the work-tree root: $root" >&2
    echo "  (your-org/nexus-code#1001)" >&2
    exit 8; }

# --- THE REFUSALS THEMSELVES (see the ENTRY GUARD header above) ------------
#
# Placed HERE, immediately after `cd "$root"`, because the very next step (the
# OVERLAY, step 0) already rewrites files. Anything that means to stop this
# script has to stop it before that line, and there is no later point at which
# "nothing has happened yet" is still true.
# NO PIPE, and the rc IS consulted. `git status --porcelain | head -c 1` reports
# HEAD's exit status, never git's (CLAUDE.md's pipeline-status entry), so a
# `git status` that failed would present as a CLEAN tree and this guard would
# wave the destructive path through. Fail CLOSED instead: a cleanliness question
# this script cannot answer is not an answer of "clean".
_bg_status=$(git status --porcelain 2>/dev/null); _bg_git_rc=$?
if [ "$_bg_git_rc" -ne 0 ] && [ "$ALLOW_DIRTY" != 1 ]; then
    echo "build.sh: REFUSING — 'git status' exited $_bg_git_rc, so this script cannot tell" >&2
    echo "  whether $root has uncommitted work. An unanswerable cleanliness check is not" >&2
    echo "  a clean tree. (your-org/nexus-code#1001)" >&2
    exit 7
fi
if [ -n "$_bg_status" ] && [ "$ALLOW_DIRTY" != 1 ]; then
    _bg_n=$(printf '%s\n' "$_bg_status" | grep -c . )
    {
        echo "build.sh: REFUSING — the working tree at $root has $_bg_n uncommitted change(s)."
        echo "  A correct target is a FRESH CLONE, which is clean by construction, so a dirty"
        echo "  tree is strong evidence this is not the tree you meant. This script rewrites"
        echo "  every tracked file IN PLACE and rm -rf's every exclude path — on a tree with"
        echo "  uncommitted work the loss is total and silent, because the scrub REWRITES"
        echo "  rather than reports and 'git status' afterwards is a wall of legitimate-looking"
        echo "  modifications. (your-org/nexus-code#1001)"
        echo "  If you meant it: build.sh --yes --allow-dirty"
    } >&2
    exit 7
fi

if [ "$ASSUME_YES" != 1 ]; then
    _bg_files=$(git ls-files | wc -l)
    _bg_syms=$(git ls-files -s | awk '$1=="120000"' | wc -l)
    _bg_excl=$(awk -F'\t' '$1=="exclude"{print $2}' "$MAP")
    _bg_excl_n=$(printf '%s\n' "$_bg_excl" | grep -c . || true)
    _bg_ren_n=0
    [ -r "$OVERLAY_DIR/renames.tsv" ] && \
        _bg_ren_n=$(grep -v '^[[:space:]]*#' "$OVERLAY_DIR/renames.tsv" | awk -F'\t' '$1=="rename"' | wc -l)
    _bg_blk_n=0
    [ -r "$OVERLAY_MANIFEST" ] && \
        _bg_blk_n=$(grep -v '^[[:space:]]*#' "$OVERLAY_MANIFEST" | awk -F'\t' '$1=="block"' | wc -l)
    {
        echo "build.sh: DRY RUN — nothing has been modified. Target: $root"
        echo "  would apply   : $_bg_blk_n overlay block(s)"
        echo "  would scrub   : $_bg_files tracked file(s) IN PLACE (of which $_bg_syms symlink(s) rewritten by TARGET, not written through)"
        echo "  would DELETE  : $_bg_excl_n excluded path(s) —"
        printf '%s\n' "$_bg_excl" | sed 's/^/                  rm -rf /'
        echo "  would rename  : $_bg_ren_n path(s)"
        echo "  head          : $(git rev-parse --short HEAD 2>/dev/null) $(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo '(detached)')"
        echo
        echo "  This is DESTRUCTIVE and IN PLACE. Re-run with --yes (or"
        echo "  NEXUS_MIRROR_BUILD_OK=1) once you are certain this is a throwaway checkout."
        echo "  Exiting 6 — NOT 0. A caller that forgot the flag must not be handed a"
        echo "  success for work that was not done. (your-org/nexus-code#1001)"
    } >&2
    exit 6
fi

# 0. OVERLAY (pre-scrub, block-level). mapping.tsv can only do single-line,
#    context-free substring substitution; a few public-fork transforms are
#    multi-line + semantic (reframe an install section, delete a note pointing
#    at an excluded page, trim a paragraph). Those are driven by the optional
#    overlay manifest and applied HERE, before the scrub, so anchors and
#    replacement content are matched/authored against the SOURCE tree. A missing
#    manifest is a no-op (a fresh operator without overlays still builds). The
#    overlay dir names internal anchors, so it is `exclude`d from the output
#    (loop 2 drops it) exactly like mapping.tsv.
apply_overlay_block() {
  local target="$1" start="$2" end="$3" repl="$4"
  [ -f "$target" ] || { echo "build.sh: overlay target missing: $target" >&2; exit 4; }
  # EMPTY START ANCHOR — refuse before anything reads it (your-org/nexus-code#1093,
  # the production half of #1038). An empty ERE matches EVERYTHING, so both the
  # drift guard below and awk's `$0 ~ start` become vacuous, and they fail in the
  # same direction: the guard reports the anchor as FOUND, then awk matches it on
  # LINE 1. With an empty `end` alongside (`state=3`) that silently truncates the
  # target to just the replacement — measured on a fixture, and this is the
  # PUBLIC-MIRROR build path.
  #
  # It is REACHABLE from data, not from a coding slip: `while IFS=$'\t' read -r
  # kind target start end repl` over a TRUNCATED manifest row (`block<TAB>target`)
  # leaves `$start` empty. Note an empty MIDDLE field does NOT get here — tab is a
  # whitespace IFS character, so consecutive tabs COLLAPSE and fields shift left
  # rather than emptying. Only truncation reaches it; the measurement is what
  # separated those two, and the first hypothesis was the wrong one.
  #
  # `$end` deliberately gets NO such check, and the reason is NOT the one first
  # written here (your-org/nexus-code#1108 skeptic F3). The load-bearing fact is
  # that its own drift guard at the foot of this function already sits behind
  # `[ -n "$end" ]`, so an empty needle never reaches that grep: there is no hole
  # to close. The first draft ALSO argued that an empty `end` is a live mode
  # (`if (end == "") { state=3 }` — delete START-to-EOF) which a check here would
  # break. That half is false, and it is worth recording why, because it is the
  # same trap `#1093` documented one step earlier: tab is an IFS WHITESPACE
  # character, so consecutive tabs COLLAPSE and an empty MIDDLE field is
  # INEXPRESSIBLE. The only manifest row reaching here with an empty `end` is a
  # 3-field truncated row, which has an empty `repl` too and exits 4 at the
  # replacement check below before awk runs. So the mode is reachable only by a
  # DIRECT call, never from the manifest, and nothing that works today would
  # break. A right conclusion on a wrong premise is what gets cited later, so
  # the premise is corrected rather than the conclusion.
  [ -n "$start" ] || {
    echo "build.sh: overlay row for $target has an EMPTY START anchor — refusing." \
         "An empty ERE matches every line, so the drift guard below would pass" \
         "vacuously and the block would be applied from line 1 (your-org/nexus-code#1093)." >&2; exit 4; }
  grep -qE -- "$start" "$target" || {
    echo "build.sh: overlay START anchor not found in $target: /$start/ (drifted?)" >&2; exit 4; }
  local replpath=""
  if [ "$repl" != "-" ]; then
    replpath="$OVERLAY_DIR/$repl"
    [ -f "$replpath" ] || { echo "build.sh: overlay replacement missing: $replpath" >&2; exit 4; }
  fi
  awk -v start="$start" -v end="$end" -v repl="$replpath" '
    function emitrepl(){ if (repl != "") { while ((getline line < repl) > 0) print line; close(repl) } }
    BEGIN { state=0 }                       # 0=before 1=inside 2=after 3=skip-to-eof
    {
      if (state==0 && $0 ~ start) {
        emitrepl()
        if (end == "") { state=3 } else { state=1 }
        next
      }
      if (state==1) { if ($0 ~ end) { print; state=2; next } else { next } }
      if (state==3) { next }
      print
    }
  ' "$target" > "$target.__o" || { echo "build.sh: overlay awk failed on $target" >&2; exit 4; }
  mv "$target.__o" "$target"
  # END anchor must have survived (proof the block boundary was found, not that
  # we silently swallowed the rest of the file when END drifted out of range).
  if [ -n "$end" ]; then
    grep -qE -- "$end" "$target" || {
      echo "build.sh: overlay END anchor gone from $target: /$end/ — block over-ran (drifted?)" >&2; exit 4; }
  fi
}
if [ -r "$OVERLAY_MANIFEST" ]; then
  while IFS=$'\t' read -r kind target start end repl; do
    [ "${kind:-}" = "block" ] || continue
    case "$kind" in \#*) continue;; esac
    apply_overlay_block "$target" "$start" "$end" "$repl"
    echo "build.sh: overlay applied to $target" >&2
  done < <(grep -v '^[[:space:]]*#' "$OVERLAY_MANIFEST")
fi

# PATH RENAMES — parsed HERE, applied at step 4. The rename rows must be read
# BEFORE step 2 drops the excluded paths, because `overlay/` is itself an
# `exclude`: by the time the renames are applied their own manifest is gone.
# Same reason the EXCL array below is captured before any deletion. Getting
# this wrong is silent — the loop simply finds no file and renames nothing,
# which is exactly how it read "0 path rename(s) applied" the first time.
RENAMES="$OVERLAY_DIR/renames.tsv"
RN_FROM=(); RN_TO=()
if [ -r "$RENAMES" ]; then
  while IFS=$'\t' read -r kind from to; do
    [ "${kind:-}" = "rename" ] || continue
    [ -n "${from:-}" ] && [ -n "${to:-}" ] || {
      echo "build.sh: malformed rename row — need FROM and TO" >&2; exit 5; }
    RN_FROM+=("$from"); RN_TO+=("$to")
  done < <(grep -v '^[[:space:]]*#' "$RENAMES")
fi

# tracked symlinks — preserve verbatim
mapfile -t SYMS < <(git ls-files -s | awk '$1=="120000"{ $1=$2=$3=""; sub(/^   /,""); print }')
is_sym(){ local f; for f in "${SYMS[@]}"; do [ "$f" = "$1" ] && return 0; done; return 1; }

# excluded paths — never scrub them in place. The scrub loop re-reads $MAP for
# every file, so scrubbing an excluded file that IS the mapping (mapping.tsv)
# rewrites the dictionary's own SOURCE column mid-run, and every file processed
# afterwards is scrubbed against a corrupted dictionary → internal identifiers
# leak. Skip excludes here; loop 2 still drops them from the output. (#537)
mapfile -t EXCL < <(awk -F'\t' '$1=="exclude"{print $2}' "$MAP")
is_excl(){ local f; for f in "${EXCL[@]}"; do [ "$f" = "$1" ] && return 0; done; return 1; }

scrub_one(){ case "$1" in *.md|*.yml|*.yaml) perl "$SCRUB" "$MAP" angle;; *) perl "$SCRUB" "$MAP" bare;; esac; }

# 1. scrub every non-symlink, non-excluded tracked file in place, preserving mode
while IFS= read -r f; do
  is_sym "$f" && continue
  is_excl "$f" && continue
  [ -f "$f" ] || continue
  m=$(git ls-files -s -- "$f" | awk '{print $1}')
  scrub_one "$f" < "$f" > "$f.__s" && mv "$f.__s" "$f"
  [ "$m" = "100755" ] && chmod +x "$f"
done < <(git ls-files)

# 1b. scrub tracked SYMLINK TARGETS by REWRITING THE LINK.
#
# Loop 1 skips symlinks and is RIGHT to: `scrub_one < "$f" > "$f"` on a symlink
# reads and truncates the TARGET FILE, which is why the header has said
# "writing through them corrupts targets" since introduction. But skipping the
# SCRUB is not the same as leaving the target path unscrubbed, and that is the
# gap: `git write-tree` publishes a symlink's blob VERBATIM, and that blob IS
# the target path. So a link to `../<internal>/x` shipped an internal token in
# the published tree while every content scan read clean — build.sh skipped it
# and leak-gate.sh could not see it. (your-org/nexus-code#1294)
#
# `ln -sfn` replaces the LINK atomically and never dereferences it, so the
# invariant loop 1 protects is preserved: the target file is never opened, read
# or written here. `-n` is load-bearing — without it, `ln -sf` onto an existing
# symlink-to-a-directory creates the new link INSIDE that directory.
for f in ${SYMS[@]+"${SYMS[@]}"}; do
  [ -n "$f" ] || continue
  is_excl "$f" && continue
  [ -L "$f" ] || continue
  old_t=$(readlink -- "$f") || {
    echo "build.sh: cannot read symlink target for $f" >&2; exit 9; }
  new_t=$(printf '%s' "$old_t" | scrub_one "$f") || {
    echo "build.sh: symlink target scrub failed for $f" >&2; exit 9; }
  # A scrub that empties the target would silently turn a link into garbage.
  # Refuse rather than publish it. (An empty target is never legitimate.)
  [ -n "$new_t" ] || {
    echo "build.sh: symlink target scrub produced an EMPTY target for $f" >&2; exit 9; }
  [ "$new_t" = "$old_t" ] && continue
  ln -sfn -- "$new_t" "$f" || {
    echo "build.sh: could not rewrite symlink $f" >&2; exit 9; }
done

# 2. drop excluded paths (mapping.tsv etc.) so internal data never ships.
#    Iterate the EXCL array captured BEFORE any deletion — $MAP itself is an
#    exclude path, so re-reading it here (after it is dropped) would fail.
for ex in "${EXCL[@]}"; do
  [ -n "$ex" ] || continue
  git rm -rq --cached --ignore-unmatch -- "$ex" >/dev/null 2>&1
  rm -rf -- "$ex"
done

# 3. FAIL LOUD if any excluded path survived (on disk or still tracked). The
# excluded paths hold the one un-scrubbed copy of the internal dictionary; a
# silently-failed drop would publish the very secrets the toolkit exists to
# strip. Never ship on a failed drop. (your-org/nexus-code#537)
survivors=0
for ex in "${EXCL[@]}"; do
  [ -n "$ex" ] || continue
  if [ -e "$ex" ] || git ls-files --error-unmatch -- "$ex" >/dev/null 2>&1; then
    echo "build.sh: FATAL — excluded path survived the drop: $ex" >&2
    survivors=$((survivors+1))
  fi
done
[ "$survivors" -eq 0 ] || { echo "build.sh: $survivors excluded path(s) still present; refusing to proceed." >&2; exit 3; }

# 4. PATH RENAMES (post-scrub). A few basenames carry an internal identifier in
#    the FILE NAME, which no amount of in-file substitution can reach. The
#    dictionary rewrites every REFERENCE to them; without this step the tree
#    would name files that do not exist, and the sync's three-way merge would
#    see the public name and the source name as two files and ship BOTH. Runs
#    AFTER the scrub on purpose: the scrub loop iterates `git ls-files`, so
#    moving a path before it runs would take the file out of the scrub.
#    Missing manifest = no-op (a fresh operator renames nothing).
#    (your-org/nexus-code#979 §2)
for i in "${!RN_FROM[@]}"; do
  from="${RN_FROM[$i]}"; to="${RN_TO[$i]}"
  [ -f "$from" ] || {
    echo "build.sh: rename source missing: $from (drifted, or already renamed?)" >&2; exit 5; }
  [ -e "$to" ] && {
    echo "build.sh: rename target already present: $to — refusing to clobber" >&2; exit 5; }
  mkdir -p -- "$(dirname -- "$to")"
  mv -- "$from" "$to" || { echo "build.sh: rename failed: $from -> $to" >&2; exit 5; }
  # Mirror the exclude-drop's index handling, so the recorded tree agrees
  # with the working tree about where this file lives.
  git add -A -- "$from" "$to" >/dev/null 2>&1
  echo "build.sh: renamed $from -> $to" >&2
done

# 5. FAIL LOUD if a rename did not take. A silently-skipped rename ships the
#    identifier the rename exists to remove — the same shape as a silently
#    -failed exclude drop, and just as unrecoverable once published.
rn_bad=0
for i in "${!RN_FROM[@]}"; do
  if [ -e "${RN_FROM[$i]}" ]; then
    echo "build.sh: FATAL — rename source still present: ${RN_FROM[$i]}" >&2; rn_bad=$((rn_bad+1))
  fi
  if [ ! -e "${RN_TO[$i]}" ]; then
    echo "build.sh: FATAL — rename target absent after the move: ${RN_TO[$i]}" >&2; rn_bad=$((rn_bad+1))
  fi
done
[ "$rn_bad" -eq 0 ] || { echo "build.sh: $rn_bad rename(s) did not take; refusing to proceed." >&2; exit 5; }

echo "build.sh: scrub applied; excluded paths dropped + verified absent; ${#RN_TO[@]} path rename(s) applied + verified. Run leak-gate.sh next."
