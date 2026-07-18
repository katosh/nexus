#!/usr/bin/env bash
# build.sh — apply the identifier scrub to the current git checkout in place,
# producing the public-mirror tree. Reproducible + data-driven: all internal
# vocabulary lives in the mapping file, nothing is hardcoded here.
#
#   build.sh [<mapping.tsv>]        (default: alongside this script)
#
# Run it on a clean checkout of the source branch (e.g. `dev`). It:
#   - scrubs every tracked file by type (.md/.yml -> angle, else bare),
#   - leaves tracked symlinks untouched (writing through them corrupts targets),
#   - preserves the executable bit,
#   - drops every `exclude` path from the tree (incl. mapping.tsv itself, so the
#     internal dictionary never ships in the public output).
# Then run leak-gate.sh to prove zero leaks (including over this toolkit's own
# files — the self-scrub check).
set -uo pipefail
export LC_ALL=C
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAP="${1:-$_here/mapping.tsv}"
SCRUB="$_here/scrub.pl"
[ -r "$MAP" ] || { echo "build.sh: mapping not readable: $MAP" >&2; exit 2; }
root=$(git rev-parse --show-toplevel) && cd "$root"

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

# 2. drop excluded paths (mapping.tsv etc.) so internal data never ships.
#    Iterate the EXCL array captured BEFORE any deletion — $MAP itself is an
#    exclude path, so re-reading it here (after it is dropped) would fail.
for ex in "${EXCL[@]}"; do
  [ -n "$ex" ] || continue
  git rm -q --cached --ignore-unmatch -- "$ex" >/dev/null 2>&1
  rm -f -- "$ex"
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

echo "build.sh: scrub applied; excluded paths dropped + verified absent. Run leak-gate.sh next."
