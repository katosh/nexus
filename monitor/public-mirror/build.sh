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

scrub_one(){ case "$1" in *.md|*.yml|*.yaml) perl "$SCRUB" "$MAP" angle;; *) perl "$SCRUB" "$MAP" bare;; esac; }

# 1. scrub every non-symlink tracked file in place, preserving mode
while IFS= read -r f; do
  is_sym "$f" && continue
  [ -f "$f" ] || continue
  m=$(git ls-files -s -- "$f" | awk '{print $1}')
  scrub_one "$f" < "$f" > "$f.__s" && mv "$f.__s" "$f"
  [ "$m" = "100755" ] && chmod +x "$f"
done < <(git ls-files)

# 2. drop excluded paths (mapping.tsv etc.) so internal data never ships
while IFS= read -r ex; do
  [ -n "$ex" ] || continue
  git rm -q --cached --ignore-unmatch -- "$ex" >/dev/null 2>&1
  rm -f -- "$ex"
done < <(awk -F'\t' '$1=="exclude"{print $2}' "$MAP")

echo "build.sh: scrub applied; excluded paths dropped. Run leak-gate.sh next."
