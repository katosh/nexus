#!/usr/bin/env bash
# Tests for the public-mirror scrub toolkit
# (monitor/public-mirror/{scrub.pl,build.sh,leak-gate.sh}).
#
# Guards the exact failure modes that blocked a mirror sync
# (your-org/nexus-code#537):
#   1. Dictionary corruption — build.sh must NOT scrub the excluded mapping
#      in place. scrub.pl re-reads the mapping per file, so scrubbing the
#      dictionary mid-run rewrites its own SOURCE column and every file
#      processed afterwards leaks. The is_excl guard must skip excludes.
#   2. Case variants — the deny gate matches case-insensitively, so the scrub
#      must too, else `SECRETORG` survives while `secretorg` is stripped.
#   3. Dictionary as leak vector — the excluded dictionary holds the one
#      un-scrubbed copy of the source identifiers. build.sh must drop it AND
#      verify it is gone (exit 3 otherwise); leak-gate must independently fail
#      if any excluded path is present in a tree bound for publication.
#   4. leak-gate is load-bearing — it must PASS a clean tree and FAIL a leak.
#
# Hermetic: builds a throwaway git repo with a SYNTHETIC dictionary (fake
# source tokens like `secretorg`, never a real internal identifier — this test
# ships to the public mirror, so it must itself be leak-clean). Only the real
# toolkit scripts under test are copied in.
#
# Run: bash monitor/test-public-mirror-scrub.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT="$_test_dir/public-mirror"
for f in scrub.pl build.sh leak-gate.sh; do
    [[ -r "$TOOLKIT/$f" ]] || { echo "FAIL: missing toolkit file $TOOLKIT/$f" >&2; echo FAILED; exit 1; }
done

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/scrubtest.XXXXXX") || exit 1
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

# --- build a hermetic fixture repo ------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/pm"
cp "$TOOLKIT/scrub.pl" "$TOOLKIT/build.sh" "$TOOLKIT/leak-gate.sh" "$REPO/pm/"

# Synthetic dictionary. `secretorg` sorts before `zzz_after.txt` on purpose so
# the corruption regression (files after the mapping leak) is exercised.
cat > "$REPO/pm/mapping.tsv" <<'MAP'
map	secretorg/tool	your-org/tool	<your-org>/tool
map	secretorg	your-org	<your-org>
map	secretuser	operator	<operator>
map	brandx/public	zzkeepasset9zz	zzkeepasset9zz
map	brandx	operator	<operator>
map	zzkeepasset9zz	brandx/public	brandx/public
map	priv-store	shared	shared
deny	secretorg
deny	secretuser
deny	brandx
deny	priv-store
keep	your-org
keep	brandx/public
exclude	pm/mapping.tsv
MAP

# A file that sorts AFTER pm/mapping.tsv — the corruption canary.
printf 'ref to secretorg and secretuser here\n' > "$REPO/zzz_after.txt"
# A file with case variants.
printf 'SECRETORG and SecretOrg and secretorg\n' > "$REPO/pm/casevar.txt"
# A markdown file (angle mode).
printf 'see secretorg/tool for details\n' > "$REPO/doc.md"
# Actor-login vs public-asset: `brandx/public` is a kept asset (deny brandx,
# keep brandx/public); a bare `@brandx` mention is the person and is mapped to
# @operator. Mirrors the operator actor-login rule (kept asset vs bare handle).
printf 'clone brandx/public and ping @brandx for review\n' > "$REPO/assets.txt"
# Slug-encoded path: a private path scrubbed to /shared must ALSO be covered in
# its dash-slug form (Claude Code slugifies /priv-store/... to -priv-store-...),
# which matches neither the slashed nor underscored literal (your-org/nexus-code#493).
printf 'session dir: -priv-store-user-x-nexus\n' > "$REPO/slug.txt"

( cd "$REPO"
  git init -q
  git config user.email t@t; git config user.name t
  git add -A; git commit -qm init )

# preserve a mapping copy for the gate (build drops the real one)
cp "$REPO/pm/mapping.tsv" "$WORK/map.tsv"

# --- run the build ----------------------------------------------------------
build_out=$( cd "$REPO" && bash pm/build.sh pm/mapping.tsv 2>&1 ); build_rc=$?

[[ $build_rc -eq 0 ]] && ok "build.sh exits 0 on a clean tree" \
                      || no "build.sh exit $build_rc (expected 0): $build_out"

# 1. corruption regression: zzz_after.txt (sorts after the dictionary) scrubbed
if grep -q secretorg "$REPO/zzz_after.txt" 2>/dev/null; then
    no "corruption: file after mapping.tsv still leaks (is_excl guard broken)"
else
    ok "no corruption: file sorting after the dictionary is fully scrubbed"
fi

# 2. case-insensitive scrub with case preservation
cv="$REPO/pm/casevar.txt"
grep -qi secretorg "$cv" && no "case variants not scrubbed" || ok "case variants scrubbed"
grep -q 'YOUR-ORG' "$cv" && ok "ALL-CAPS match -> upper-cased replacement" \
                         || no "ALL-CAPS SECRETORG did not upper-case: $(cat "$cv")"

# 2b. actor-login vs public-asset: mention scrubbed, asset kept
av="$REPO/assets.txt"
grep -q '@brandx' "$av" && no "actor-login @brandx not scrubbed: $(cat "$av")" \
                        || ok "actor-login @brandx scrubbed to @operator"
grep -q 'brandx/public' "$av" && ok "kept public asset brandx/public survives the scrub" \
                              || no "kept asset brandx/public was wrongly scrubbed: $(cat "$av")"
grep -rq 'zzkeepasset9' "$REPO" 2>/dev/null && no "asset-protect sentinel leaked into output" \
                                            || ok "asset-protect sentinel fully restored (no leakage)"

# 2c. slug-encoded path form is scrubbed (dash form of a denylisted path)
sv="$REPO/slug.txt"
grep -q 'priv-store' "$sv" && no "slug-encoded path not scrubbed: $(cat "$sv")" \
                           || ok "slug-encoded path form scrubbed"

# 3a. dictionary dropped from output
[[ -e "$REPO/pm/mapping.tsv" ]] && no "dictionary still present after build" \
                                || ok "dictionary dropped from output tree"

# 3b. leak-gate: clean tree PASSES
gate_out=$( cd "$REPO" && bash pm/leak-gate.sh "$WORK/map.tsv" . 2>&1 ); gate_rc=$?
[[ $gate_rc -eq 0 ]] && ok "leak-gate PASS on clean scrubbed tree" \
                     || no "leak-gate FAIL on clean tree (rc=$gate_rc): $gate_out"

# 4. leak-gate: planted leak FAILS
printf 'oops secretuser slipped in\n' > "$REPO/leak.txt"
( cd "$REPO" && git add leak.txt )
( cd "$REPO" && bash pm/leak-gate.sh "$WORK/map.tsv" . >/dev/null 2>&1 ) \
    && no "leak-gate PASSED a planted leak (not load-bearing)" \
    || ok "leak-gate FAILS on a planted leak"
( cd "$REPO" && git rm -q leak.txt >/dev/null 2>&1 )

# 4b. a NON-asset use of a keep-listed token (brandx/private) still FAILS —
#     the keep-list exempts only the specific asset form, not the bare token.
printf 'internal ref brandx/private here\n' > "$REPO/leak2.txt"
( cd "$REPO" && git add leak2.txt )
( cd "$REPO" && bash pm/leak-gate.sh "$WORK/map.tsv" . >/dev/null 2>&1 ) \
    && no "leak-gate PASSED a non-asset use of a keep-listed token" \
    || ok "leak-gate FAILS on a non-asset use of a keep-listed token"
( cd "$REPO" && git rm -q leak2.txt >/dev/null 2>&1 )

# 5. dictionary guard: an excluded path present in the tree FAILS the gate
cp "$WORK/map.tsv" "$REPO/pm/mapping.tsv"
( cd "$REPO" && git add pm/mapping.tsv )
dg_out=$( cd "$REPO" && bash pm/leak-gate.sh "$WORK/map.tsv" . 2>&1 ); dg_rc=$?
if [[ $dg_rc -ne 0 ]] && printf '%s' "$dg_out" | grep -qi 'excluded'; then
    ok "leak-gate FAILS when the excluded dictionary is present in the tree"
else
    no "leak-gate did not flag a present excluded dictionary (rc=$dg_rc): $dg_out"
fi
( cd "$REPO" && git rm -q pm/mapping.tsv >/dev/null 2>&1; rm -f pm/mapping.tsv )

# 6. build.sh survivor assertion: if a drop is impossible, refuse (exit 3).
#    Simulate by making the exclude path a non-removable read-only dir entry is
#    fragile; instead assert the guard code path exists and the happy path
#    already reported "verified absent".
printf '%s' "$build_out" | grep -q 'verified absent' \
    && ok "build.sh reports excludes verified-absent (survivor assertion active)" \
    || no "build.sh did not run the survivor assertion: $build_out"

echo
if [[ $fail -eq 0 ]]; then
    echo "ALL TESTS PASSED ($pass checks)"
    exit 0
else
    echo "FAILED ($fail of $((pass+fail)) checks)"
    exit 1
fi
