#!/usr/bin/env bash
# Tests for monitor/_fm_lib.sh — the ONE keyed field reader/writer that the
# frontmatter channels and the bare-kv token records share (#405 P2).
#
# Covers:
#   A. LEGACY PARITY — the new `_fm_get`/`_kv_get` are byte-for-byte identical
#      to the three parsers they replaced (_chan_frontmatter_field, the client
#      reply_state, and the token `sed -n 's/^expires=//p'|head -1`) over a
#      battery of realistic inputs.
#   B. ADVERSARIAL READS — leading/trailing spaces, `:`/`=` in value, empty
#      value, value containing `---`, CRLF, key in-and-after fence, absent key,
#      duplicated key (first wins).
#   C. ENUMERATED EDGE DIVERGENCES — the two adversarial inputs on which the
#      lenient new parser DELIBERATELY differs from a legacy parser; asserted so
#      the (documented, non-occurring) difference is a tracked choice, not a
#      silent regression.
#   D. WRITES — update-in-place preserves order; insert lands inside the fence;
#      kv append; missing-file / no-fence creation; atomicity (temp+mv, no
#      leftover temp; a reader never sees a torn file).
#   E. CLIENT MIRROR — the in-bundle _fm_get in monitor/client/_nexus_watch_lib.sh
#      agrees with the server _fm_get (the anti-drift guarantee for the confined
#      client, which cannot source the server lib).
#
# Run: bash monitor/watcher/test-fm-lib.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_test_dir/.." && pwd)
# shellcheck source=/dev/null
. "$_monitor_dir/_fm_lib.sh"
CLIENT_LIB="$_monitor_dir/client/_nexus_watch_lib.sh"

PASS=0; FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}
assert_ne() {
    local label="$1" a="$2" b="$3"
    if [[ "$a" != "$b" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — expected difference, both %q\n' "$label" "$a" >&2; FAIL=$((FAIL+1)); fi
}
assert_file_eq() {
    local label="$1" f="$2" want="$3"
    local got; got=$(cat "$f")
    assert_eq "$label" "$got" "$want"
}
assert_rc() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — rc %s want %s\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — missing %q\n    in: <<%s>>\n' "$label" "$needle" "$hay" >&2; FAIL=$((FAIL+1)); fi
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fmlib.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- the three LEGACY parsers, verbatim from the pre-P2 sources ----------
old_chan_ff() {   # was monitor/_channel_lib.sh:_chan_frontmatter_field
    local file="$1" key="$2"
    [[ -r "$file" ]] || return 1
    awk -v k="$key" '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---" { exit }
        infm {
            if ($0 ~ "^" k ":[[:space:]]*") {
                sub("^" k ":[[:space:]]*", "", $0)
                print $0
                exit
            }
        }
    ' "$file"
}
old_reply_state() {   # was monitor/client/_nexus_watch_lib.sh:reply_state
    awk '
        NR==1 && /^---[[:space:]]*$/ { infm=1; next }
        infm && /^---[[:space:]]*$/  { exit }
        infm && /^state:[[:space:]]/ { sub(/^state:[[:space:]]*/,""); print; exit }
    ' "$1" 2>/dev/null
}
old_expires() { sed -n 's/^expires=//p' "$1" 2>/dev/null | head -1; }

# =========================================================================
echo "A. legacy parity — frontmatter reads (_fm_get vs the two old awk parsers)"
# The realistic corpus: exactly the bytes request-channel.sh writes.
cat > "$WORK/new.md" <<'EOF'
---
kind: question
origin: remote-bob
state: new
---

Summarize work/foo.
EOF
cat > "$WORK/replied.md" <<'EOF'
---
kind: question
reply:
  worker: win7
  dir: work/foo
origin: remote-bob
state: replied
---

## Reply

done.
EOF
cat > "$WORK/statebody.md" <<'EOF'
---
origin: remote-x
state: new
---

body line that says state: SPOOF and origin: SPOOF
EOF
# absent-key + no-frontmatter fixtures
printf 'no frontmatter here\nstate: loose\n' > "$WORK/nofm.md"

for f in new replied statebody nofm; do
    for k in kind origin state reply nope; do
        n=$(_fm_get "$WORK/$f.md" "$k")
        o=$(old_chan_ff "$WORK/$f.md" "$k")
        assert_eq "parity _fm_get vs old_chan_ff [$f/$k]" "$n" "$o"
    done
    ns=$(_fm_get "$WORK/$f.md" state)
    os=$(old_reply_state "$WORK/$f.md")
    assert_eq "parity _fm_get(state) vs old_reply_state [$f]" "$ns" "$os"
done

echo
echo "A2. legacy parity — bare kv reads (_kv_get vs old sed|head -1)"
printf 'principal=remote-bob\nexpires=1750000000\n' > "$WORK/a.token"
printf 'expires=42\nprincipal=x\nexpires=999\n'      > "$WORK/dup.token"   # first wins
printf 'principal=only\n'                            > "$WORK/noexp.token" # absent
printf 'expires=a=b=c\n'                             > "$WORK/eqval.token" # '=' in value
for t in a dup noexp eqval; do
    n=$(_kv_get "$WORK/$t.token" expires)
    o=$(old_expires "$WORK/$t.token")
    assert_eq "parity _kv_get vs old_expires [$t]" "$n" "$o"
done

echo
echo "B. adversarial reads"
# leading/trailing spaces in the value (frontmatter trims LEADING ws after colon)
printf -- '---\nk:    padded value   \n---\n' > "$WORK/pad.md"
assert_eq "fm leading ws trimmed, trailing kept" "$(_fm_get "$WORK/pad.md" k)" "padded value   "
# ':' inside a frontmatter value
printf -- '---\nk: a:b:c\n---\n' > "$WORK/colon.md"
assert_eq "fm colon-in-value" "$(_fm_get "$WORK/colon.md" k)" "a:b:c"
# empty value
printf -- '---\nk:\nj: \n---\n' > "$WORK/empty.md"
assert_eq "fm empty value (no ws)" "$(_fm_get "$WORK/empty.md" k)" ""
assert_eq "fm empty value (one ws)" "$(_fm_get "$WORK/empty.md" j)" ""
# value containing --- (must not be read as a fence; round-trips)
printf -- '---\nk: ---\n---\n' > "$WORK/dash.md"
assert_eq "fm value is ---" "$(_fm_get "$WORK/dash.md" k)" "---"
# key appearing BOTH inside and after the fence → the in-fence one wins
printf -- '---\nstate: inside\n---\nstate: outside\n' > "$WORK/inout.md"
assert_eq "fm in-fence wins over post-fence" "$(_fm_get "$WORK/inout.md" state)" "inside"
# key ONLY after the fence → not seen (empty)
printf -- '---\norigin: x\n---\nstate: outside\n' > "$WORK/onlyout.md"
assert_eq "fm post-fence-only key not seen" "$(_fm_get "$WORK/onlyout.md" state)" ""
# duplicated key inside fence → first wins
printf -- '---\nk: first\nk: second\n---\n' > "$WORK/dupk.md"
assert_eq "fm duplicate key first wins" "$(_fm_get "$WORK/dupk.md" k)" "first"
# CRLF file: \r is part of the value (byte-faithful; parity with legacy awk)
printf -- '---\r\nstate: new\r\n---\r\n' > "$WORK/crlf.md"
assert_eq "fm CRLF: new parser retains trailing CR" "$(_fm_get "$WORK/crlf.md" state)" "$(printf 'new\r')"
assert_eq "fm CRLF: matches legacy reply_state"     "$(_fm_get "$WORK/crlf.md" state)" "$(old_reply_state "$WORK/crlf.md")"
# C1-class divergence on CRLF: old_chan_ff's STRICT `$0=="---"` never matches a
# `---\r` line, so it reads NOTHING from a CRLF file; the lenient new parser (and
# reply_state) read through it. The two legacy parsers themselves disagree here;
# the new one matches the lenient one. request-channel.sh writes LF, so CRLF
# never occurs — this is the same strict-vs-lenient fence class as edge C1.
assert_eq "fm CRLF: old_chan_ff (strict) reads nothing" "$(old_chan_ff "$WORK/crlf.md" state)" ""
assert_ne "fm CRLF: new vs old_chan_ff divergence tracked (C1-class)" "$(_fm_get "$WORK/crlf.md" state)" "$(old_chan_ff "$WORK/crlf.md" state)"
# absent file
assert_eq "fm absent file → empty" "$(_fm_get "$WORK/does-not-exist.md" k)" ""
# kv adversarial: '=' in value, prefix guard, trailing spaces kept
printf 'k=a=b\n' > "$WORK/kveq.token";    assert_eq "kv = in value" "$(_kv_get "$WORK/kveq.token" k)" "a=b"
printf 'kk=other\nk=v\n' > "$WORK/kvpfx.token"; assert_eq "kv prefix guard (kk vs k)" "$(_kv_get "$WORK/kvpfx.token" k)" "v"
printf 'k=  spaced  \n' > "$WORK/kvsp.token"; assert_eq "kv value byte-faithful (no trim)" "$(_kv_get "$WORK/kvsp.token" k)" "  spaced  "

echo
echo "C. enumerated edge divergences (lenient new parser vs stricter legacy)"
# C1: a line-1 opening fence with TRAILING whitespace. Legacy _chan required an
# EXACT '---'; the new (and reply_state-style) lenient parser treats it as a
# fence. request-channel.sh only ever writes a bare '---', so this never occurs.
printf -- '---   \nstate: X\n---\n' > "$WORK/fencews.md"
assert_eq  "edge: new lenient reads through trailing-ws fence" "$(_fm_get "$WORK/fencews.md" state)" "X"
assert_eq  "edge: old_chan_ff (strict) reads nothing"          "$(old_chan_ff "$WORK/fencews.md" state)" ""
assert_ne  "edge C1 divergence is real + tracked" "$(_fm_get "$WORK/fencews.md" state)" "$(old_chan_ff "$WORK/fencews.md" state)"
# C2: 'state:' with NO space before the value. Legacy reply_state required >=1
# space (/^state:[[:space:]]/) and returns nothing; the new parser returns the
# value. The server always writes 'state: <v>' with a space, so never occurs.
printf -- '---\nstate:tight\n---\n' > "$WORK/nospace.md"
assert_eq  "edge: new reads no-space colon value" "$(_fm_get "$WORK/nospace.md" state)" "tight"
assert_eq  "edge: old_reply_state reads nothing"  "$(old_reply_state "$WORK/nospace.md")" ""

echo
echo "D. writes — update/insert/append/atomicity"
# update-in-place preserves order + siblings
cat > "$WORK/w1.md" <<'EOF'
---
a: 1
b: 2
c: 3
---

body
EOF
_fm_put "$WORK/w1.md" b TWO
assert_file_eq "fm update-in-place preserves order" "$WORK/w1.md" "$(printf -- '---\na: 1\nb: TWO\nc: 3\n---\n\nbody')"
# insert lands INSIDE the fence, before the closing ---
_fm_put "$WORK/w1.md" d 4
assert_file_eq "fm insert before closing fence" "$WORK/w1.md" "$(printf -- '---\na: 1\nb: TWO\nc: 3\nd: 4\n---\n\nbody')"
# adversarial put values round-trip through get
_fm_put "$WORK/w1.md" x "a:b ---"
assert_eq "fm put/get round-trip (colon + dashes + space)" "$(_fm_get "$WORK/w1.md" x)" "a:b ---"
_fm_put "$WORK/w1.md" a ""
assert_eq "fm put empty value round-trip" "$(_fm_get "$WORK/w1.md" a)" ""
# frontmatter put on a file with NO fence → creates one, keeps old body
printf 'just a body line\n' > "$WORK/w2.md"
_fm_put "$WORK/w2.md" state new
assert_file_eq "fm put creates fence on unfenced file" "$WORK/w2.md" "$(printf -- '---\nstate: new\n---\njust a body line')"
# frontmatter put on a MISSING file → creates fenced file
_fm_put "$WORK/w3.md" state new
assert_file_eq "fm put creates missing file" "$WORK/w3.md" "$(printf -- '---\nstate: new\n---\n')"
# kv update in place
printf 'principal=x\nexpires=1\n' > "$WORK/k1.token"
_kv_put "$WORK/k1.token" expires 999
assert_file_eq "kv update-in-place" "$WORK/k1.token" "$(printf 'principal=x\nexpires=999')"
# kv append (absent key)
_kv_put "$WORK/k1.token" newk hello
assert_file_eq "kv append absent key at EOF" "$WORK/k1.token" "$(printf 'principal=x\nexpires=999\nnewk=hello')"
# kv put on missing file → creates one record
_kv_put "$WORK/k2.token" expires 5
assert_file_eq "kv put creates missing file" "$WORK/k2.token" "expires=5"
# atomicity: temp built in the destination dir, mv -f'd; no .fmput.* left behind
_fm_put "$WORK/w1.md" y 7
_kv_put "$WORK/k1.token" z 8
leftover=$(find "$WORK" -maxdepth 1 -name '.fmput.*' | wc -l | tr -d ' ')
assert_eq "no leftover temp files (atomic temp+mv)" "$leftover" "0"

echo
echo "F. write core does NOT escape-process values (the awk -v regression)"
# F1: a literal two-char backslash-n in the value must NOT become a real newline
# and must NOT inject a phantom `injected:` field. This is the exact exploit the
# skeptic proved against the old `awk -v val` path.
pwn='v\ninjected: PWNED'          # literal backslash + n, NOT a newline
printf -- '---\nstate: new\n---\n' > "$WORK/inj.md"
_fm_put "$WORK/inj.md" k "$pwn"
assert_eq "F1 value round-trips byte-faithful (literal \\n kept)" "$(_fm_get "$WORK/inj.md" k)" "$pwn"
assert_eq "F1 NO phantom 'injected' field is gettable"           "$(_fm_get "$WORK/inj.md" injected)" ""
# kv variant of the same
printf 'principal=x\nexpires=1\n' > "$WORK/inj.token"
_kv_put "$WORK/inj.token" k "$pwn"
assert_eq "F1 kv value round-trips byte-faithful" "$(_kv_get "$WORK/inj.token" k)" "$pwn"
assert_eq "F1 kv NO phantom 'injected' record"    "$(_kv_get "$WORK/inj.token" injected)" ""
# F2: every backslash class round-trips sha-identical through write→read.
#   tab, literal \t \n \\ sequences, a trailing backslash, and a value that
#   only LOOKS like an injection after a backslash-n.
declare -a VALS=(
    'plain'
    'a\tb\nc'
    'has\\backslashes\\'
    'trailing\'
    'tab	inside'
    'looks: like:yaml but is one value'
)
i=0
for v in "${VALS[@]}"; do
    i=$((i+1))
    printf -- '---\nstate: new\n---\n' > "$WORK/rt$i.md"
    _fm_put "$WORK/rt$i.md" payload "$v"
    got=$(_fm_get "$WORK/rt$i.md" payload)
    assert_eq "F2 fm round-trip [$i] byte-faithful" "$got" "$v"
    # sha of a file that is exactly `value` vs the put-then-get value
    printf '%s' "$v"   > "$WORK/rt$i.want"
    printf '%s' "$got" > "$WORK/rt$i.got"
    assert_eq "F2 fm round-trip [$i] sha-identical" "$(sha_of "$WORK/rt$i.got")" "$(sha_of "$WORK/rt$i.want")"
    # kv path too
    printf 'principal=x\n' > "$WORK/rt$i.token"
    _kv_put "$WORK/rt$i.token" payload "$v"
    assert_eq "F2 kv round-trip [$i] byte-faithful" "$(_kv_get "$WORK/rt$i.token" payload)" "$v"
done
# a value with a REAL newline cannot be a single-line record → rejected loudly
printf -- '---\nstate: new\n---\n' > "$WORK/nl.md"
_fm_put "$WORK/nl.md" k "$(printf 'a\nb')" 2>/dev/null
assert_rc "F1 real-newline value rejected (rc 2)" "$?" "2"
assert_eq "F1 rejected put wrote nothing"          "$(_fm_get "$WORK/nl.md" k)" ""

echo
echo "G. unclosed fence fails LOUDLY (no silent lost write)"
# opening fence, key present, but NO closing fence → must fail, write nothing.
printf -- '---\nstate: new\nother: y\n' > "$WORK/unclosed.md"
before=$(sha_of "$WORK/unclosed.md")
err=$(_fm_put "$WORK/unclosed.md" state replied 2>&1); rc=$?
assert_rc "G unclosed-fence put fails nonzero" "$rc" "1"
assert_contains "G stderr names the malformed fence" "$err" "no closing fence"
assert_eq "G file unchanged (no silent write)" "$(sha_of "$WORK/unclosed.md")" "$before"
# a lone opening fence is likewise malformed
printf -- '---\n' > "$WORK/lone.md"
_fm_put "$WORK/lone.md" state x 2>/dev/null
assert_rc "G lone opening fence fails nonzero" "$?" "1"

echo
echo "H. keys are identifier-charset (validated in get AND put)"
printf -- '---\nstate: new\n---\n' > "$WORK/kk.md"
_fm_get "$WORK/kk.md" 'bad key' >/dev/null 2>&1; assert_rc "H _fm_get rejects space in key"  "$?" "2"
_fm_get "$WORK/kk.md" 'a:b'     >/dev/null 2>&1; assert_rc "H _fm_get rejects colon in key"  "$?" "2"
_fm_get "$WORK/kk.md" ''        >/dev/null 2>&1; assert_rc "H _fm_get rejects empty key"     "$?" "2"
_kv_get "$WORK/inj.token" 'x.y' >/dev/null 2>&1; assert_rc "H _kv_get rejects dot in key"    "$?" "2"
_fm_put "$WORK/kk.md" 'bad key' v >/dev/null 2>&1; assert_rc "H _fm_put rejects space in key" "$?" "2"
_kv_put "$WORK/inj.token" 'a=b' v >/dev/null 2>&1; assert_rc "H _kv_put rejects = in key"     "$?" "2"
assert_eq "H rejected fm_put wrote nothing" "$(_fm_get "$WORK/kk.md" state)" "new"
# the client mirror validates too (POSIX case guard)
bash -c '. "$1"; _fm_get "$2" "bad key"' _ "$CLIENT_LIB" "$WORK/kk.md" >/dev/null 2>&1
assert_rc "H client _fm_get rejects bad key" "$?" "2"

echo
echo "E. client mirror agrees with server _fm_get"
# The client lib defines its OWN _fm_get (same name, mirror). Run it in a
# subshell so it doesn't clobber the server _fm_get sourced here, and compare.
# fencews/nospace are the C1/C2 divergence fixtures (created in section C):
# the mirror must side with the LENIENT server reader on both, not with the
# stricter legacy parsers.
for f in new replied statebody crlf inout fencews nospace; do
    server=$(_fm_get "$WORK/$f.md" state)
    client=$(bash -c '. "$1"; _fm_get "$2" state' _ "$CLIENT_LIB" "$WORK/$f.md")
    assert_eq "client mirror == server _fm_get(state) [$f]" "$client" "$server"
    # and the client's reply_state wrapper == its _fm_get(state)
    rs=$(bash -c '. "$1"; reply_state "$2"' _ "$CLIENT_LIB" "$WORK/$f.md")
    assert_eq "client reply_state == client _fm_get(state) [$f]" "$rs" "$client"
done
# Pin the C1/C2 values explicitly so the parity asserts above can never
# degrade into comparing two empty strings.
assert_eq "client mirror reads through C1 trailing-ws fence" \
    "$(bash -c '. "$1"; _fm_get "$2" state' _ "$CLIENT_LIB" "$WORK/fencews.md")" "X"
assert_eq "client mirror reads C2 no-space colon value" \
    "$(bash -c '. "$1"; _fm_get "$2" state' _ "$CLIENT_LIB" "$WORK/nospace.md")" "tight"

echo
if (( FAIL == 0 )); then echo "ALL TESTS PASSED ($PASS)"; exit 0
else echo "SOME TESTS FAILED ($FAIL failed, $PASS passed)" >&2; exit 1; fi
