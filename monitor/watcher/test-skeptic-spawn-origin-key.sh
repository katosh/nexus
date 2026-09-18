#!/usr/bin/env bash
# your-org/nexus-code#960 — THE LOSSY SANITISER UPSTREAM OF THE ENCODER.
#
# `ng`'s `_wrapup_file_spawn_skeptic_request` derived its request `--origin`
# with `"${target//[^A-Za-z0-9_-]/_}"` — `wk_legacy_key` written by hand, with
# the character ranges spelled `A-Za-z` instead of `a-zA-Z`. That spelling is
# why #941's sweep and three skeptic passes all missed it: a grep for the
# defect IDIOM is sensitive to how the class is written.
#
# WHY NO WRITER/READER AGREEMENT CHECK CAN SEE IT. `_chan_safe` IS `wk_encode`
# and `request-channel.sh` reads back through it, so both ends agree exactly.
# The loss is UPSTREAM of the encoder: `lossy ∘ injective` is lossy, and a
# destroyed pre-image is invisible to any check that compares two ends.
#
# Two consequences, and the first is reached by a SUPPRESSED WRITE rather than
# by a deletion — which is why #941's deletion-scoped "count of nine" is
# honest and still excluded it:
#
#   F1  the idempotency globs key on `origin`, so `a.b`'s REQUIRED
#       spawn-skeptic request is silently `skipped (already filed)` while
#       `a_b`'s sits in the inbox. A required skeptic never runs.
#   F2  `windows/${origin}.json` was a cross-window HIT, not a miss. `a.b`
#       does not LOSE its provenance — it ADOPTS `a_b`'s, and files a request
#       carrying another window's prompt_file and session_id.
#
# EVERY ABSENCE HERE IS PAIRED WITH A POSITIVE CONTROL, because "no request
# was filed" and "this path files nothing ever" are the same bytes.
#
# Run: bash monitor/watcher/test-skeptic-spawn-origin-key.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
NG="$_repo_root/monitor/ng"
BK="$_repo_root/monitor/_bookkeeping.sh"
RC="$_repo_root/monitor/request-channel.sh"

# The SHARED helpers, not a hand-rolled set — so this suite is `ledger=yes`
# AND `count=exact` and needs no row in `summary-honesty.manifest`. The ledger
# certifies no FAIL was swallowed by a subshell (your-org/nexus-code#805); the
# `_EXPECTED_ASSERTIONS` guard at the bottom reddens a VANISHED assertion
# (#807). Different properties, neither implying the other. Their
# `assert_contains` carries the same empty-needle guard (#1092) a hand-rolled
# copy here used to duplicate.
#
# ORDER MATTERS: sourced BEFORE `source "$NG"` below, so that if `ng` ever
# defines a colliding name it is `ng`'s own definition the driven function
# sees. The assertions are called from this file's top level, never from
# inside `ng`, so nothing here depends on the helpers surviving that source.
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

[[ -x "$NG" ]] || { echo "missing $NG" >&2; exit 1; }
[[ -r "$BK" ]] || { echo "missing $BK" >&2; exit 1; }
[[ -x "$RC" ]] || { echo "missing $RC" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── THE AMBIENT STATE DIR, CAPTURED BEFORE ANYTHING OVERRIDES IT ──────────
#
# The containment check in §2 must name the directory the tool would have
# written to WITHOUT the override — not this clone's. When this suite's probe
# leaked, `NEXUS_ROOT` was inherited pointing at the PRIMARY nexus, so the
# eight stray requests landed under `<primary>/monitor/.state/requests` while
# `$_repo_root/monitor/.state` stayed empty. A negative control aimed at the
# clone is INERT against exactly the failure it exists to catch — caught by
# `wskl`, reviewing this suite, and it is the same shape as the suite's
# subject: a check asserting a property it never tested.
#
# Mirrors `request-channel.sh:_resolve_state_dir`'s order. If neither variable
# is set the fallback is this clone, which is then the right answer anyway.
_AMBIENT_STATE="${NEXUS_STATE_DIR:-}"
[[ -n "$_AMBIENT_STATE" || -z "${NEXUS_ROOT:-}" ]] || _AMBIENT_STATE="$NEXUS_ROOT/monitor/.state"
[[ -n "$_AMBIENT_STATE" ]] || _AMBIENT_STATE="$_repo_root/monitor/.state"
# A DELTA, not a zero: the ambient inbox is live and may legitimately already
# hold anything, including this suite's own historical leak.
# Counts ARRAY MEMBERS, not lines. Two reasons and both are load-bearing:
# a filename may contain a newline, which no line count survives; and
# `textguard-lint`'s R1 exists because `grep -c` counts LINES while its reader
# thinks it counts things. The unit here is FILES, so count files.
_probe_count() {
    local line; local -a f=()
    while IFS= read -r line; do f+=("$line"); done \
        < <(find "$1/requests" -maxdepth 1 -name '*originprobe*' 2>/dev/null)
    printf '%s' "${#f[@]}"
}
_AMBIENT_BEFORE=$(_probe_count "$_AMBIENT_STATE")
_CLONE_BEFORE=$(_probe_count "$_repo_root/monitor/.state")

# _request_body <state-dir> <request-id> — the ONE request file's bytes.
#
# NOT `cat "$d/requests/${id}".*.md`. That pairs a possibly-empty GLOB with a
# command having a MEANINGFUL BARE FORM: under `nullglob` an unmatched glob
# VANISHES and `cat` reads STDIN — which, in a suite whose stdin is inherited,
# BLOCKS. That is CLAUDE.md's SHOPT-DYNAMIC-SCOPE entry, and it fired on this
# file from `nullglob-bare-form-manifest.sh`, which is the right outcome: the
# hazard is removed rather than dispositioned `safe`.
#
# Resolving the path first is also a BETTER ASSERTION. A body concatenated from
# an unknown number of files proves less than one from exactly one, and "no
# file at all" would otherwise reach `assert_not_contains` as an EMPTY string,
# which passes every "does not contain" check vacuously.
_request_body() {
    local d="$1" id="$2" line
    local -a f=()
    while IFS= read -r line; do f+=("$line"); done \
        < <(find "$d/requests" -maxdepth 1 -name "${id}.*.md" 2>/dev/null | sort)
    (( ${#f[@]} == 1 )) || {
        printf '<<FIXTURE BROKEN: expected exactly 1 request file for %s, found %d>>' \
            "$id" "${#f[@]}"
        return 1
    }
    cat -- "${f[0]}"
}

# ===========================================================================
echo '=== 1. wk_encode_word: injective into the validator alphabet ==='
# ===========================================================================
# shellcheck disable=SC1090
source "$BK"

for _fn in wk_encode_word wk_decode_word; do
    assert_eq "$_fn is defined" \
        "$(declare -F "$_fn" >/dev/null && echo yes || echo NO)" "yes"
done

# The corpus deliberately includes:
#   `a.b` / `a_b`   the #960 collider pair
#   `a_2Eb`         a RAW name that LOOKS like `a.b`'s key — the pre-image
#                   collision a naive `.`->`_XX` scheme would create
#   `a__b`          the escape, doubled, as raw input
#   `_x` / `x_`     escape at each boundary
#   `a/b`, `a b`, `a%b`   the characters the two encoders disagree about
_CORPUS=( 'nc-wmerge' 'wgate' 'a.b' 'a_b' 'a-b' 'a_2Eb' 'a__b' '_x' 'x_'
          'a b' 'a%b' 'a/b' 'cc-update-2.1.183' )

_rt_bad=0 _val_bad=0
for _n in "${_CORPUS[@]}"; do
    _e=$(wk_encode_word "$_n")
    [[ "$_e" =~ ^[A-Za-z0-9_-]+$ ]] || { _val_bad=$(( _val_bad + 1 )); printf '    validator-reject: %q -> %q\n' "$_n" "$_e" >&2; }
    if _d=$(wk_decode_word "$_e"); then
        [[ "$_d" == "$_n" ]] || { _rt_bad=$(( _rt_bad + 1 )); printf '    roundtrip: %q -> %q -> %q\n' "$_n" "$_e" "$_d" >&2; }
    else
        _rt_bad=$(( _rt_bad + 1 )); printf '    decode REFUSED its own output: %q -> %q\n' "$_n" "$_e" >&2
    fi
done
assert_eq "round-trips for every name in the corpus (${#_CORPUS[@]})" "$_rt_bad" "0"
assert_eq "…and every key is spellable in request-channel's [A-Za-z0-9_-]" "$_val_bad" "0"

# INJECTIVITY, asserted as a set equality rather than exemplified: distinct
# names in, distinct keys out. This is the property the whole fix rests on, so
# it is measured, not argued.
_n_names=$(printf '%s\n' "${_CORPUS[@]}" | sort -u | grep -c .)
_n_keys=$(for _n in "${_CORPUS[@]}"; do printf '%s\n' "$(wk_encode_word "$_n")"; done | sort -u | grep -c .)
assert_eq "injective on the corpus: distinct keys == distinct names" "$_n_keys" "$_n_names"

# THE POSITIVE CONTROL FOR THAT ASSERTION. The OLD map must actually collide
# on this corpus — otherwise the equality above passes for want of a hazard
# and proves nothing.
_n_legacy=$(for _n in "${_CORPUS[@]}"; do printf '%s\n' "$(wk_legacy_key "$_n")"; done | sort -u | grep -c .)
assert_eq "POSITIVE CONTROL: the legacy map COLLIDES on the same corpus" \
    "$( (( _n_legacy < _n_names )) && echo collides || echo NO )" "collides"

# The declared non-identity, stated in _bookkeeping.sh and asserted here so it
# cannot be quietly "fixed" into a collision.
assert_eq "declared: NOT the identity on \`_\` — the escape is doubled" \
    "$(wk_encode_word 'a_b')" "a__b"
assert_eq "…and the identity on a name needing nothing" \
    "$(wk_encode_word 'nc-wmerge')" "nc-wmerge"

# wk_decode_word REFUSES a string it could not have produced. "Could not
# decode" must not degrade into a plausible pre-image.
#
# TWO SHAPES, and only the second discriminates (your-org/nexus-code#1354).
# The first three are MALFORMED — a trailing bare `_`, `_` before non-hex —
# and any decoder refuses them for a reason unrelated to the claim. The rest
# are WELL-FORMED BUT IMPOSSIBLE: `_XX` whose byte the encoder passes through
# (`_2D` -> `-`, `_41` -> `A`, `_61` -> `a`, `_30` -> `0`), the escape spelled
# as hex (`_5F` -> `_`, which the encoder writes `__`), and lowercase hex
# (`_5f`, which the encoder never emits). Until #1354 the decoder ACCEPTED all
# six and returned a plausible pre-image at rc 0, while this loop passed on
# the malformed three alone — a control that could not fail the way the claim
# can.
for _bad in 'a_' 'a_zz' 'a_Z0'   'a_5F' 'a_5f' 'a_2D' 'a_41' 'a_61' 'a_30'; do
    wk_decode_word "$_bad" >/dev/null 2>&1
    assert_eq "decode REFUSES ${_bad@Q} (rc 1), never invents a pre-image" "$?" "1"
done
# POSITIVE CONTROL for the tightening: keys the encoder DOES emit still decode.
# A decoder that refused every `_XX` would pass the loop above.
assert_eq "…while a genuine escape still decodes (a_2Eb -> a.b)" "$(wk_decode_word 'a_2Eb')" "a.b"
assert_eq "…and the doubled escape still decodes (a__b -> a_b)"  "$(wk_decode_word 'a__b')"  "a_b"

# ===========================================================================
echo '=== 2. the request-channel validator agrees, by execution ==='
# ===========================================================================
# The alphabet claim above is a regex in THIS file. Drive the real validator
# so the two cannot drift: `a.b`'s key must be ACCEPTED, and `wk_encode`'s
# `%`-bearing key must be REJECTED — which is #960 F3, why the naive fix is
# wrong.
# NEXUS_STATE_DIR, **not** `STATE_DIR` — `request-channel.sh` computes its own
# `STATE_DIR` at load time from `NEXUS_STATE_DIR` -> `NEXUS_ROOT` -> config, so
# an exported `STATE_DIR` is OVERWRITTEN and ignored. A first draft of this
# block did exactly that and filed EIGHT probe requests into the operator's
# LIVE inbox in ninety seconds, each one firing a watcher emit the operator
# then acked by hand. The env var was wrong and nothing said so: the probe
# succeeded, which is what it was asserting, in the wrong tree.
#
# The general form, since it is this suite's own subject: A TEST THAT WRITES
# MUST PROVE WHERE IT WROTE. Redirecting a tool by env var is a CLAIM about
# that tool's resolution order — so assert the artefact landed in the scratch
# root before drawing any conclusion from the call's status.
_VS="$WORK/vroot"; mkdir -p "$_VS/monitor/.state/requests"
_file_origin() {   # <origin> -> rc of `request-channel file`
    printf 'probe body for the origin validator\n' \
        | env -u STATE_DIR NEXUS_STATE_DIR="$_VS/monitor/.state" \
              NEXUS_ROOT="$_VS" \
              "$RC" file --origin "$1" --kind question \
              --slug originprobe --priority normal - >/dev/null 2>&1
    return $?
}
# READ `$?` INTO A VARIABLE ON THE VERY NEXT LINE. Writing
# `assert_eq "… $(wk_encode_word x)" "$?" 0` destroys the status before it is
# read: arguments evaluate left to right, so the substitution in the MESSAGE
# runs and writes `$?` first. That is CLAUDE.md's PRINTF-STATUS-CLOBBER, and
# it was hit while writing this suite — the rc read `0` for a REJECTED call.
_ok_word=$(wk_encode_word 'a.b')
_ok_pct=$(wk_encode 'a.b')
_file_origin "$_ok_word"; _rc_word=$?
_file_origin "$_ok_pct";  _rc_pct=$?
assert_eq "request-channel ACCEPTS wk_encode_word('a.b') = $_ok_word" "$_rc_word" "0"
assert_eq "POSITIVE CONTROL (#960 F3): it REJECTS wk_encode('a.b') = $_ok_pct" \
    "$( (( _rc_pct != 0 )) && echo rejected || echo ACCEPTED )" "rejected"
# CONTAINMENT, ASSERTED. The accepted call above must have written into the
# scratch root and NOWHERE ELSE. Both directions: the artefact is HERE (so the
# redirect worked and the rc means what it says), and the repo's own
# `monitor/.state/requests` gained nothing (so it did not also go there).
# `-maxdepth 1 -name '*.new.md'`: one filed request also mints a `replies/`
# directory and an `.ids/` entry under the same stem, so an unqualified `find`
# counts 3 for 1 request. Count the ARTEFACT, not everything named after it.
# Array members again, for the reasons at `_probe_count`. The claim is
# MEMBERSHIP of the scratch tree — exactly one artefact — never placement.
_scratch_probes=(); while IFS= read -r _l; do _scratch_probes+=("$_l"); done \
    < <(find "$_VS/monitor/.state/requests" -maxdepth 1 -name '*originprobe*.new.md' 2>/dev/null)
assert_eq "the probe's request landed in the SCRATCH root" \
    "${#_scratch_probes[@]}" "1"
# THE NEGATIVE DIRECTION, aimed at the AMBIENT dir rather than at this clone —
# see the capture above for why that distinction is the whole assertion. A
# DELTA, because the ambient inbox is live: "unchanged" is the property, not
# "empty". Both are checked, since the two paths differ whenever a worker runs
# under a primary's NEXUS_ROOT, which is the normal case.
assert_eq "…and the AMBIENT inbox ($_AMBIENT_STATE) is UNCHANGED" \
    "$(_probe_count "$_AMBIENT_STATE")" "$_AMBIENT_BEFORE"
assert_eq "…and so is this clone's own state dir" \
    "$(_probe_count "$_repo_root/monitor/.state")" "$_CLONE_BEFORE"

# ===========================================================================
echo '=== 3. F1: a colliding window no longer suppresses a REQUIRED request ==='
# ===========================================================================
# Driven against the real `_wrapup_file_spawn_skeptic_request` in an isolated
# STATE_DIR, exactly as #960 measured it.
unset NEXUS_WORKER_WINDOW
export NEXUS_STATE_DIR="$WORK/.state"
mkdir -p "$NEXUS_STATE_DIR/requests" "$NEXUS_STATE_DIR/windows"
# shellcheck disable=SC1090
source "$NG"

_REPORT="$WORK/report.md"
printf -- '---\nwindow: a.b\ndisposition: no-further-pass\n---\n\n## Summary\n\nbody\n' > "$_REPORT"

_file_for() {   # <target> -> the function's own stdout verdict
    _SK_SPAWN_REQ=1 _SK_SPAWN_TARGET="$1" _SK_SPAWN_DEPTH=1 \
    _SK_SPAWN_ORIG="$1" _SK_SPAWN_MODE=require _SK_SPAWN_EFFECTIVE=required \
    _SK_SPAWN_DELIBERATE=0 _SK_SPAWN_REASONS='' _SK_SPAWN_CONTRADICTED='' \
    _SK_PINNED_NOTIFIED='' \
        _wrapup_file_spawn_skeptic_request 42 "$_REPORT" - - - owner/repo 2>/dev/null
}

# PLANT BY EXECUTION, NOT BY CONSTRUCTION. An earlier draft wrote the plant
# under `wk_encode_word 'a_b'` — the key the FIXED code computes — so the
# defect mutant, which computes a DIFFERENT key, could not see the plant and
# the assertion passed while the defect was live. A guard that only fails on
# text is a proxy for the property, and this suite exists because of proxies.
#
# So `a_b` files its own request through the real function. Whatever key the
# code under test uses, the plant is under it, and the assertion below is
# then about the PROPERTY — two distinct windows do not suppress each other —
# for every implementation, including the broken ones.
_out_plant=$(_file_for 'a_b')
assert_contains "FIXTURE: window \`a_b\` files its own request first" "$_out_plant" "filed"

_out_ab=$(_file_for 'a.b')
assert_contains "F1: \`a.b\`'s required request is FILED despite \`a_b\`'s plant" "$_out_ab" "filed"
assert_not_contains "…and is NOT suppressed as 'already filed'" "$_out_ab" "already filed"

# THE SUPPRESSION MUST STILL WORK — the fix must not have disabled idempotency
# wholesale, which would pass the assertion above for the wrong reason.
_out_ab2=$(_file_for 'a.b')
assert_contains "POSITIVE CONTROL: a SECOND \`a.b\` request IS suppressed" "$_out_ab2" "already filed"

# NEGATIVE CONTROL for the plant itself: `a_b` sees its own request.
_out_a_b=$(_file_for 'a_b')
assert_contains "NEGATIVE CONTROL: \`a_b\` still sees its own request" "$_out_a_b" "already filed"

# ===========================================================================
echo '=== 4. F2: provenance is read under the STATE key, not the origin ==='
# ===========================================================================
# `windows/<key>.json` is written by _bookkeeping.sh under `wk_encode`. Plant
# `a_b`'s record there and assert `a.b` does NOT adopt it.
rm -f "$NEXUS_STATE_DIR"/requests/*.md
printf '{"window":"a_b","prompt_file":"/prompts/A_B-SECRET.md","session_id":"SESSION-OF-a_b"}\n' \
    > "$NEXUS_STATE_DIR/windows/$(wk_encode 'a_b').json"
# The correctly-encoded record for `a.b` is ABSENT, so any hit is purely the key.
rm -f "$NEXUS_STATE_DIR/windows/$(wk_encode 'a.b').json"

_id=$(_file_for 'a.b'); _id="${_id#filed }"
_body=$(_request_body "$NEXUS_STATE_DIR" "$_id")
assert_contains "FIXTURE: a request body was produced to inspect" "$_body" "spawn-skeptic"
assert_not_contains "F2: \`a.b\` does NOT adopt \`a_b\`'s prompt_file" "$_body" "/prompts/A_B-SECRET.md"
assert_not_contains "F2: …nor \`a_b\`'s session_id" "$_body" "SESSION-OF-a_b"

# POSITIVE CONTROL: the read is not simply dead. Plant the CORRECTLY-encoded
# record and the same call must pick it up.
rm -f "$NEXUS_STATE_DIR"/requests/*.md
printf '{"window":"a.b","prompt_file":"/prompts/A-DOT-B.md","session_id":"SESSION-OF-a.b"}\n' \
    > "$NEXUS_STATE_DIR/windows/$(wk_encode 'a.b').json"
_id2=$(_file_for 'a.b'); _id2="${_id2#filed }"
_body2=$(_request_body "$NEXUS_STATE_DIR" "$_id2")
assert_contains "POSITIVE CONTROL: the correctly-keyed record IS read" "$_body2" "/prompts/A-DOT-B.md"
assert_contains "…including its session id" "$_body2" "SESSION-OF-a.b"

# ===========================================================================
echo '=== 5. the defect idiom is gone from the call site ==='
# ===========================================================================
# Keyed on the CONSTRUCT, in BOTH spellings, because the spelling is the whole
# reason #960 survived three passes. A future author who re-introduces it in
# either order lands red here.
_ngsrc=$(grep -vE '^[[:space:]]*#' "$NG")
assert_eq "no hand-spelled legacy sanitiser survives in \`ng\` (either range order)" \
    "$(grep -cE '\$\{target//\[\^(A-Za-z|a-zA-Z)0-9_-\]/_\}' <<<"$_ngsrc" || true)" "0"
assert_eq "the spawn-request origin comes from wk_encode_word" \
    "$(grep -c 'origin=$(wk_encode_word "$target")' <<<"$_ngsrc" || true)" "1"
assert_eq "the provenance record is keyed by wk_encode" \
    "$(grep -c 'windows/\$(wk_encode "\$target").json' <<<"$_ngsrc" || true)" "1"

# ===========================================================================
_EXPECTED_ASSERTIONS=37
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
