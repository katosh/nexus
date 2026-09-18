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
# And the failure modes that blocked the next one (your-org/nexus-code#979 §2):
#   5. THE VACUOUS GREEN — the gate reads its `deny` patterns from the same file
#      the scrub reads its `map` rules from, so a category nobody wrote down is
#      invisible to BOTH and the gate reports clean rather than reporting a
#      miss. §8 pins both halves: absent category -> passes; taught -> fails.
#   6. A rule anchored to a token that collides with an ordinary idiom corrupts
#      working code. §9 pins the sentinel round-trip that brackets it.
#   7. A denied identifier in a file NAME shipped with every check green —
#      `git grep` reads contents. §10 pins the path check.
#   8. Renaming references without renaming the FILE leaves the tree naming
#      paths that do not exist. §11 pins build.sh's rename step and its refusal.
#   9. The gate reads the WORKING TREE; `git write-tree` — the publish path —
#      reads the INDEX. When they disagree a PASS describes an artifact nobody
#      would push, and omitting one recipe line shipped 512 unscrubbed files
#      with the gate green. §12 pins the refusal, and that it did not displace
#      the gate's actual job.
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
map	secretorg/secretpack	your-org/genpack	<your-org>/genpack
map	secretpack	genpack	genpack
map	secretorg	your-org	<your-org>
map	secretuser	operator	<operator>
map	brandx/public	zzkeepasset9zz	zzkeepasset9zz
map	brandx	operator	<operator>
map	zzkeepasset9zz	brandx/public	brandx/public
map	priv-store	shared	shared
deny	secretorg
deny	secretpack
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
# Group-namespaced remote whose middle token also appears BARE (models the
# your-org/hpc-skills remote: a group-owned repo `ORG/pack` where `pack` is
# also a standalone name in prose/paths, with a qualified `ORG/pack` rule, a
# bare `pack` rule, AND a generic `ORG/` collapse). The ordering hazard: the
# bare or generic rule could fire on a qualified occurrence first and leave a
# half-scrubbed `ORG/newpack` or `neworg/pack`. Longest-first ordering must send
# every `ORG/pack` straight to the single coherent `neworg/newpack`. Mirrors
# install-hpc-skills.sh:42's `REMOTE_URL=...github.com/secretorg/secretpack.git`.
printf 'REMOTE_URL="${PACK_REMOTE:-https://github.com/secretorg/secretpack.git}"\n' > "$REPO/pack-install.txt"

( cd "$REPO"
  git init -q
  git config user.email t@t; git config user.name t
  git add -A; git commit -qm init )

# preserve a mapping copy for the gate (build drops the real one)
cp "$REPO/pm/mapping.tsv" "$WORK/map.tsv"

# --- run the build ----------------------------------------------------------
build_out=$( cd "$REPO" && bash pm/build.sh --yes pm/mapping.tsv 2>&1 ); build_rc=$?
# STAGE, exactly as the corrected sync recipe does. `build.sh` scrubs the
# working tree and does not stage; `git write-tree` records the index. The gate
# now REFUSES when the two disagree (exit 5), because a PASS on an unstaged tree
# describes an artifact nobody would push — see §12.
( cd "$REPO" && git add -A ) >/dev/null 2>&1

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
if [[ $dg_rc -ne 0 ]] && grep -qi 'excluded' <<<"$dg_out"; then
    ok "leak-gate FAILS when the excluded dictionary is present in the tree"
else
    no "leak-gate did not flag a present excluded dictionary (rc=$dg_rc): $dg_out"
fi
( cd "$REPO" && git rm -q pm/mapping.tsv >/dev/null 2>&1; rm -f pm/mapping.tsv )

# 6. build.sh survivor assertion: if a drop is impossible, refuse (exit 3).
#    Simulate by making the exclude path a non-removable read-only dir entry is
#    fragile; instead assert the guard code path exists and the happy path
#    already reported "verified absent".
grep -q 'verified absent' <<<"$build_out" \
    && ok "build.sh reports excludes verified-absent (survivor assertion active)" \
    || no "build.sh did not run the survivor assertion: $build_out"

# 7. group-namespaced remote (models the your-org/hpc-skills remote).
#    a) The built fixture's REMOTE_URL is a SINGLE coherent generic URL — no
#       half-scrub (neither `secretorg/genpack` nor `your-org/secretpack`), and
#       no surviving denied token (secretorg / secretpack).
pi="$REPO/pack-install.txt"
if grep -q 'https://github.com/your-org/genpack.git' "$pi" \
   && ! grep -Eq 'secretorg|secretpack|your-org/secretpack|secretorg/genpack' "$pi"; then
    ok "group-namespaced remote scrubs to a single coherent generic URL"
else
    no "group-namespaced remote incoherent after build: $(cat "$pi")"
fi
#    b) Ordering across remote FORMS: qualified `ORG/pack` must beat both the
#       bare `pack` rule and the generic `ORG/` collapse for every occurrence
#       shape (https, ssh, no-.git, bare, bare-adjacent). Drive scrub.pl directly
#       (build drops the mapping; the gate copy at $WORK/map.tsv is the dictionary).
scrub_bare(){ printf '%s' "$1" | perl "$TOOLKIT/scrub.pl" "$WORK/map.tsv" bare; }
ord_ok=1
while IFS='|' read -r in want; do
    got=$(scrub_bare "$in")
    [[ "$got" == "$want" ]] || { ord_ok=0; no "ordering: '$in' -> '$got' (want '$want')"; }
    # No half-scrub / deny-tripping residue in any case.
    case "$got" in *secretorg*|*secretpack*) ord_ok=0; no "ordering: residue in '$got'";; esac
done <<'CASES'
https://github.com/secretorg/secretpack.git|https://github.com/your-org/genpack.git
git@github.com:secretorg/secretpack.git|git@github.com:your-org/genpack.git
https://github.com/secretorg/secretpack|https://github.com/your-org/genpack
secretorg/secretpack|your-org/genpack
~/.cache/secretpack|~/.cache/genpack
clone secretorg/secretpack ; note the bare secretpack|clone your-org/genpack ; note the bare genpack
CASES
[[ $ord_ok -eq 1 ]] && ok "group-namespaced remote: every occurrence shape scrubs coherently (no half-scrub)"

# --- 8. THE VACUOUS GREEN (your-org/nexus-code#979 §2) -----------------------
#
# The defining property of this toolkit's failure mode, pinned as a test rather
# than left as folklore. The gate reads its `deny` patterns from the SAME file
# the scrub reads its `map` rules from, so an identifier category nobody wrote
# down is invisible to both: not stripped, and not flagged. The gate reports
# CLEAN where the honest answer is "I was never told to look."
#
# Both halves are asserted. The first is the uncomfortable one — a green that
# means nothing — and it is asserted deliberately so that anyone who later makes
# the gate detect unknown categories has to come here and change it on purpose.
mini_gate() {   # <mapping-file> <file-content>; echoes PASS or FAIL
    local map="$1" content="$2" d="$WORK/mini.$RANDOM"
    mkdir -p "$d"; printf '%s\n' "$content" > "$d/f.txt"
    ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
        && git add -A && git commit -qm p ) >/dev/null 2>&1
    if ( cd "$d" && bash "$TOOLKIT/leak-gate.sh" "$map" . >/dev/null 2>&1 ); then
        echo PASS; else echo FAIL; fi
    rm -rf "$d"
}

# A dictionary that knows nothing about the `qzcorp` category.
cat > "$WORK/map-blind.tsv" <<'MAP'
map	secretorg	your-org	<your-org>
deny	secretorg
exclude	pm/mapping.tsv
MAP
# The same dictionary, taught the category — anchored to the specific
# identifiers, never to the bare two-letter token.
cat > "$WORK/map-seeing.tsv" <<'MAP'
map	secretorg	your-org	<your-org>
map	install-qz-pack	install-pub-pack	install-pub-pack
map	qz_probe_installed	pub_probe_installed	pub_probe_installed
map	qzhost	genericnode	genericnode
deny	secretorg
deny	install-qz-pack
deny	qz_probe_installed
deny	\bqzhost\b
exclude	pm/mapping.tsv
MAP

blind_all_miss=1; seeing_all_catch=1
while IFS='|' read -r label content; do
    [[ -n "$label" ]] || continue
    [[ "$(mini_gate "$WORK/map-blind.tsv" "$content")" == PASS ]] || blind_all_miss=0
    [[ "$(mini_gate "$WORK/map-seeing.tsv" "$content")" == FAIL ]] || seeing_all_catch=0
done <<'CASES'
installer basename|ref to install-qz-pack.sh here
probe function name|call qz_probe_installed now
cluster hostname|host =~ ^(qzhost)
CASES
[[ $blind_all_miss -eq 1 ]] \
    && ok "a category ABSENT from the dictionary passes the gate (this is the vacuity, not cleanliness)" \
    || no "expected the blind dictionary to miss every planted category"
[[ $seeing_all_catch -eq 1 ]] \
    && ok "the same tokens FAIL the gate once the category is in the dictionary" \
    || no "the taught dictionary failed to catch a planted category"

# --- 9. anchored rule + sentinel protection of a colliding idiom -------------
#
# The abbreviation that names the category is also an ordinary identifier
# elsewhere — the real dictionary's is two letters and collides with the Python
# file-handle idiom `fh.read()` / `fh.write()`. A rule keyed on the bare token
# corrupts working code, so the namespace rule is bracketed by a sentinel
# round-trip: park the idiom, rewrite the namespace, restore.
cat > "$WORK/map-sentinel.tsv" <<'MAP'
map	qz.read	zzidiom1zz	zzidiom1zz
map	qz.write	zzidiom2zz	zzidiom2zz
map	qz.	pub.	pub.
map	zzidiom1zz	qz.read	qz.read
map	zzidiom2zz	qz.write	qz.write
deny	qz\.
keep	qz\.(read|write)\b
exclude	pm/mapping.tsv
MAP
sent_in='use qz.tool and qz.other; with open(p) as qz: qz.read(); qz.write(x)'
sent_out=$(printf '%s' "$sent_in" | perl "$TOOLKIT/scrub.pl" "$WORK/map-sentinel.tsv" bare)
if [[ "$sent_out" == 'use pub.tool and pub.other; with open(p) as qz: qz.read(); qz.write(x)' ]]; then
    ok "sentinel round-trip: namespace rewritten, colliding idiom byte-identical"
else
    no "sentinel round-trip corrupted the colliding idiom: $sent_out"
fi
[[ "$sent_out" == *zzidiom* ]] && no "sentinel token leaked into the scrub output" \
                               || ok "no sentinel token survives the round-trip"
# …and the gate agrees: the idiom line is kept, a namespace use is not.
[[ "$(mini_gate "$WORK/map-sentinel.tsv" 'with open(p) as qz: qz.read()')" == PASS ]] \
    && ok "gate keeps a line carrying only the colliding idiom" \
    || no "gate flagged the protected idiom (keep-list not applied)"
[[ "$(mini_gate "$WORK/map-sentinel.tsv" 'see the qz.tool namespace')" == FAIL ]] \
    && ok "gate flags a namespace use of the same prefix" \
    || no "gate missed a namespace use"

# --- 10. leak-gate reads PATHS, not only contents ----------------------------
#
# A denied identifier in a file NAME shipped with every check green: `git grep`
# reads contents. Nothing but an operator's memory kept such names off the
# mirror. Found by a mutant that deleted a rename row.
pdir="$WORK/pathleak"; mkdir -p "$pdir"
printf 'nothing denied in here\n' > "$pdir/install-qz-pack.sh"
( cd "$pdir" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm p ) >/dev/null 2>&1
pg_out=$( cd "$pdir" && bash "$TOOLKIT/leak-gate.sh" "$WORK/map-seeing.tsv" . 2>&1 ); pg_rc=$?
if (( pg_rc != 0 )) && grep -q 'file PATH' <<<"$pg_out"; then
    ok "leak-gate FAILS on a denied token in a file NAME (contents clean)"
else
    no "leak-gate missed a denied token in a path (rc=$pg_rc): $pg_out"
fi
rm -rf "$pdir"

# --- 11. build.sh applies PATH RENAMES, and fails loud when one cannot ------
#
# The dictionary rewrites every REFERENCE to a renamed file; without the rename
# the tree names files that do not exist. Measured on the real tree: adding the
# reference rules without the rename took a suite from 34 passed / 0 failed to
# 11 / 23.
rn_repo="$WORK/rnrepo"; mkdir -p "$rn_repo/pm/overlay" "$rn_repo/sub"
cp "$TOOLKIT/scrub.pl" "$TOOLKIT/build.sh" "$TOOLKIT/leak-gate.sh" "$rn_repo/pm/"
cat > "$WORK/rn-map.tsv" <<'MAP'
map	install-qz-pack	install-pub-pack	install-pub-pack
deny	install-qz-pack
exclude	pm/mapping.tsv
MAP
cp "$WORK/rn-map.tsv" "$rn_repo/pm/mapping.tsv"
printf 'run ./sub/install-qz-pack.sh to install\n' > "$rn_repo/README.md"
printf '#!/bin/sh\necho installing\n' > "$rn_repo/sub/install-qz-pack.sh"
printf 'rename\tsub/install-qz-pack.sh\tsub/install-pub-pack.sh\n' > "$rn_repo/pm/overlay/renames.tsv"
( cd "$rn_repo" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
rn_out=$( cd "$rn_repo" && bash pm/build.sh --yes pm/mapping.tsv 2>&1 ); rn_rc=$?
if (( rn_rc == 0 )) && [[ -f "$rn_repo/sub/install-pub-pack.sh" ]] \
   && [[ ! -e "$rn_repo/sub/install-qz-pack.sh" ]]; then
    ok "build.sh renames a declared path and removes the old one"
else
    no "rename did not take (rc=$rn_rc): $rn_out"
fi
# The reference and the file agree — the whole point of the step.
if grep -q 'install-pub-pack.sh' "$rn_repo/README.md" \
   && ! grep -q 'install-qz-pack' "$rn_repo/README.md"; then
    ok "references and the renamed path agree after the build"
else
    no "reference/path disagreement after rename: $(cat "$rn_repo/README.md")"
fi
# A rename whose SOURCE is gone must REFUSE, not shrug: a silently-skipped
# rename ships the identifier the rename exists to remove.
# Built fresh rather than copied from the tree above: that one has already had
# its dictionary dropped (the drop is a `git rm --cached`, so `git checkout` does
# not bring it back) and build.sh would refuse for the wrong reason — rc 2, not
# the rc 5 under test. A fixture that fails for a reason other than the one you
# are asserting is a green you cannot spend.
rn2="$WORK/rnrepo2"; mkdir -p "$rn2/pm/overlay" "$rn2/sub"
cp "$TOOLKIT/scrub.pl" "$TOOLKIT/build.sh" "$TOOLKIT/leak-gate.sh" "$rn2/pm/"
cp "$WORK/rn-map.tsv" "$rn2/pm/mapping.tsv"
printf 'run ./sub/install-qz-pack.sh to install\n' > "$rn2/README.md"
printf '#!/bin/sh\necho installing\n' > "$rn2/sub/install-qz-pack.sh"
printf 'rename\tsub/not-there.sh\tsub/whatever.sh\n' > "$rn2/pm/overlay/renames.tsv"
( cd "$rn2" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
rn2_out=$( cd "$rn2" && bash pm/build.sh --yes pm/mapping.tsv 2>&1 ); rn2_rc=$?
if (( rn2_rc == 5 )) && grep -q 'rename source missing' <<<"$rn2_out"; then
    ok "build.sh exits 5 when a rename SOURCE is missing (drifted manifest)"
else
    no "missing rename source did not refuse (rc=$rn2_rc): $(tail -2 <<<"$rn2_out")"
fi

# --- 12. the gate refuses a tree it cannot vouch for -------------------------
#
# `build.sh` scrubs the WORKING TREE and does not stage; `git write-tree` — the
# publish path — records the INDEX. When they disagree a PASS describes an
# artifact nobody would push. Measured on a fully-fixed tree
# (your-org/nexus-code#979 F2): omit `git add -A` from the recipe and the gate
# returned 0 while the tree write-tree produced carried 512 leaking files. The
# remedy was a README line; a documented step that silently ships 512 unscrubbed
# files when skipped is not a remedy, so the gate now refuses.
gdir="$WORK/staging"; mkdir -p "$gdir"
printf 'clean content\n' > "$gdir/f.txt"
( cd "$gdir" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm p ) >/dev/null 2>&1
# Clean tree: index == working tree, so the gate answers normally.
( cd "$gdir" && bash "$TOOLKIT/leak-gate.sh" "$WORK/map-seeing.tsv" . >/dev/null 2>&1 )
[[ $? -eq 0 ]] && ok "gate PASSES when index and working tree agree" \
               || no "gate did not pass a clean, staged tree"
# Unstaged edit: the gate must REFUSE (5), not pass (0) and not report a leak (1).
printf 'edited but not staged\n' >> "$gdir/f.txt"
( cd "$gdir" && bash "$TOOLKIT/leak-gate.sh" "$WORK/map-seeing.tsv" . >/dev/null 2>&1 )
gs_rc=$?
[[ $gs_rc -eq 5 ]] && ok "gate REFUSES (exit 5) when the index and working tree disagree" \
                   || no "gate returned $gs_rc for an unstaged tree; expected 5 (0 would vouch for a tree nobody ships)"
# The deliberate working-copy scan is still available, and says what it covers.
gs_out=$( cd "$gdir" && bash "$TOOLKIT/leak-gate.sh" "$WORK/map-seeing.tsv" . --allow-unstaged 2>&1 ); gs2_rc=$?
if [[ $gs2_rc -eq 0 ]] && grep -q 'WORKING TREE only' <<<"$gs_out"; then
    ok "--allow-unstaged proceeds AND states that its verdict covers the working tree only"
else
    no "--allow-unstaged did not proceed with a scoped verdict (rc=$gs2_rc)"
fi
# Staging the same edit makes the two agree again — the refusal is about
# disagreement, not about having edited anything.
( cd "$gdir" && git add -A && bash "$TOOLKIT/leak-gate.sh" "$WORK/map-seeing.tsv" . >/dev/null 2>&1 )
[[ $? -eq 0 ]] && ok "staging the edit clears the refusal (it is about disagreement, not about edits)" \
               || no "gate still refused after staging"
# And a real leak is still a leak once staged — the refusal must not have
# replaced the gate's actual job.
printf 'qzhost\n' > "$gdir/leak.txt"
( cd "$gdir" && git add -A && bash "$TOOLKIT/leak-gate.sh" "$WORK/map-seeing.tsv" . >/dev/null 2>&1 )
[[ $? -eq 1 ]] && ok "a staged tree carrying a denied token still FAILS (exit 1)" \
               || no "the staging check displaced the leak check"

echo
if [[ $fail -eq 0 ]]; then
    echo "ALL TESTS PASSED ($pass checks)"
    exit 0
else
    echo "FAILED ($fail of $((pass+fail)) checks)"
    exit 1
fi
