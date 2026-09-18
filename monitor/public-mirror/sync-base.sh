#!/usr/bin/env bash
# sync-base.sh — produce the CORRECT three-way merge base for a mirror sync.
#
#   sync-base.sh <outdir> [<source-sha>]
#
# Writes a scrubbed tree into <outdir> and prints one `key=value` line per fact
# on stdout. <source-sha> defaults to the last row of sync-log.tsv.
#
# THE TRAP THIS EXISTS TO CLOSE (your-org/nexus-code#979 §5). Reconstructing the
# mirror as a three-way merge is sound. The MERGE BASE decides whether it is
# correct, and it fails SILENTLY, in the leakier direction.
#
# Take a file that did not change between the two source commits, and a
# dictionary rule that improved between them — leaky value L, good value G.
#
#   CORRECT base = scrub_old(source_old)      (what the previous sync shipped)
#       base   L
#       ours   L        the mirror, carrying what shipped
#       theirs G        today's scrub
#     -> only `theirs` moved. The merge takes G. Right.
#
#   WRONG base   = scrub_now(source_old)      (old source, TODAY's dictionary)
#       base   G        the improvement is now IN the base
#       ours   L
#       theirs G
#     -> the merge reads `ours` as a deliberate public-side revert G -> L and
#        `theirs` as unchanged. It takes L. No conflict. No diagnostic. The
#        older, leakier value wins and the dictionary improvement is undone.
#
# Nothing errors, nothing is flagged, and the loss is exactly proportional to
# how much the dictionary has improved — the better you have made the scrub,
# the more the wrong base silently throws away.
#
# WHY IT IS CHEAP TO GET RIGHT. The dictionary is versioned in the same
# repository as the source, so `scrub_old(source_old)` is just "check out
# source_old — dictionary, overlay, renames and all — and run build.sh". There
# is no old dictionary to reconstruct. The entire trap is using the CURRENT
# checkout's dictionary against an OLD source tree, which is what you get by
# default if you build the base any other way. This script removes the chance.
#
# It also runs the pipeline in the order the recipe needs: build, then
# `git add -A`, then the gate. `build.sh` scrubs the WORKING TREE and does not
# stage; `git write-tree` records the INDEX. Skip the staging step and the
# published tree is the UNSCRUBBED one while `leak-gate` — which reads the
# working tree — reports it clean. Measured on this repo: 509 files
# modified-unstaged after a build, and one file alone carried 12 occurrences of
# an internal identifier into `git write-tree`'s output.
#
# Exit: 0 = base built and gate-clean. 2 = bad usage / unresolvable sha.
#       3 = build failed. 4 = the base does NOT pass the leak gate.

set -uo pipefail
export LC_ALL=C

_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LEDGER="$_here/sync-log.tsv"

die(){ echo "sync-base.sh: $1" >&2; exit "${2:-2}"; }

OUTDIR="${1:-}"
[ -n "$OUTDIR" ] || die "usage: sync-base.sh <outdir> [<source-sha>]"
[ -e "$OUTDIR" ] && die "outdir already exists: $OUTDIR (refusing to build a base over existing state)"

SRC_ROOT=$(git -C "$_here" rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside a git work tree"

# The toolkit's path RELATIVE to the repo root, derived rather than hardcoded:
# the same commands then address the throwaway clone, and the script is
# exercisable against a fixture repo that does not mirror this layout. A
# hardcoded `monitor/public-mirror/...` would make every hermetic test of this
# file a test of a different file.
case "$_here" in
    "$SRC_ROOT"/*) REL_PM="${_here#"$SRC_ROOT"/}" ;;
    "$SRC_ROOT")   REL_PM="." ;;
    *) die "toolkit dir $_here is not inside $SRC_ROOT" ;;
esac

SHA="${2:-}"
if [ -z "$SHA" ]; then
    [ -r "$LEDGER" ] || die "no source sha given and no ledger at $LEDGER — record the previous sync, or pass the sha explicitly"
    SHA=$(awk -F'\t' '!/^[[:space:]]*#/ && $1=="sync" && $3 != "" {s=$3} END{print s}' "$LEDGER")
    [ -n "$SHA" ] || die "ledger $LEDGER has no sync rows — the previous sync did not record itself, so the base cannot be derived. Pass the sha explicitly and then ADD the row."
    echo "source=ledger" >&2
fi

# Resolve BEFORE cloning, so a typo fails here rather than after a 15 s build.
# A sha absent from the local object store is not "absent from the repo" — it
# may simply never have been fetched (your-org/nexus-code#814), so say so.
FULL=$(git -C "$SRC_ROOT" rev-parse --verify --quiet "${SHA}^{commit}") \
    || die "cannot resolve '$SHA' in $SRC_ROOT — if it is a real commit, this clone may never have fetched it; run 'git fetch' and retry"

git clone -q --no-hardlinks "$SRC_ROOT" "$OUTDIR" 2>/dev/null \
    || die "could not clone $SRC_ROOT into $OUTDIR"
git -C "$OUTDIR" checkout -q --detach "$FULL" \
    || die "could not check out $FULL in $OUTDIR"

# The whole point: the dictionary, the overlay manifest and the rename manifest
# now all come from THAT commit, because they are versioned alongside the
# source. Building here is `scrub_old(source_old)` by construction.
# `--yes`: the destructive step is now opt-in (your-org/nexus-code#1001). This
# clone is fresh, detached and clean by construction (L92-95 above), so no
# `--allow-dirty` is needed or wanted here — if this tree is ever dirty, that
# is a bug in this script and the refusal is the right outcome.
build_out=$( cd "$OUTDIR" && bash "$REL_PM/build.sh" --yes 2>&1 ); build_rc=$?
if (( build_rc != 0 )); then
    printf '%s\n' "$build_out" >&2
    die "build.sh exit $build_rc at $FULL" 3
fi

# STAGE, then gate. The order is not cosmetic — see the header.
git -C "$OUTDIR" add -A >/dev/null 2>&1 \
    || die "could not stage the scrubbed tree in $OUTDIR"

# The dictionary is dropped by the build, so the gate needs the copy that lives
# at the commit being built. Read it out of the object store rather than off
# disk, where it no longer exists.
MAPTMP="$OUTDIR/.sync-base-mapping.tsv"
if git -C "$SRC_ROOT" cat-file -e "${FULL}:${REL_PM}/mapping.tsv" 2>/dev/null; then
    git -C "$SRC_ROOT" show "${FULL}:${REL_PM}/mapping.tsv" > "$MAPTMP" 2>/dev/null
fi
if [ -s "$MAPTMP" ]; then
    gate_out=$( cd "$OUTDIR" && bash "$REL_PM/leak-gate.sh" "$MAPTMP" . 2>&1 ); gate_rc=$?
    rm -f "$MAPTMP"
    if (( gate_rc != 0 )); then
        printf '%s\n' "$gate_out" | sed 's/:[0-9]*:.*//' >&2
        die "the merge base does NOT pass its own leak gate at $FULL — do not merge against it" 4
    fi
    gate=clean
else
    rm -f "$MAPTMP"
    # No dictionary at that commit means no gate can be run, which is a fact
    # about the base, not a clearance. Say so rather than printing gate=clean.
    gate=UNCHECKED
fi

TREE=$(git -C "$OUTDIR" write-tree) || die "git write-tree failed in $OUTDIR"

echo "base_source_sha=$FULL"
echo "base_tree=$TREE"
echo "base_dir=$OUTDIR"
echo "gate=$gate"
echo "renames=$(grep -c '^build\.sh: renamed ' <<<"$build_out")"
echo "overlays=$(grep -c '^build\.sh: overlay applied to ' <<<"$build_out")"
