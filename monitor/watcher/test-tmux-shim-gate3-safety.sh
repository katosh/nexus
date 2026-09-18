#!/usr/bin/env bash
# test-tmux-shim-gate3-safety.sh — a planted `tmux` shim must be PROVABLY
# unable to reach a wrapper (your-org/nexus-code#1105, #1115, #1117).
#
# THE HAZARD. A fixture isolates tmux by planting a `tmux` shim that pins
# `-L <private socket>` and fronting its directory on $PATH. In this workspace
# that shim is reached THROUGH monitor/tmuxwrap, because $BASH_ENV force-fronts
# the wrapper ahead of any $PATH a suite exports. tmuxwrap picks "the first
# $PATH tmux that is not a wrapper", and its gate-3 calls a candidate a wrapper
# if its first 40 lines carry a gate-3 signature. So a shim whose body NAMES the
# wrapper is skipped, tmuxwrap resolves the real tmux with NO -L, `$TMUX`
# outranks `$TMUX_TMPDIR` (#644), and the client lands on THE OPERATOR'S BOARD.
# On 2026-08-27 that pasted AND SUBMITTED a fixture payload into the live
# orchestrator pane as four user-role turns.
#
# ── WHY THIS FILE WAS REWRITTEN, WHICH IS THE POINT ────────────────────────
#
# Its first version claimed to "key on the PROPERTY rather than on a spelling".
# That claim was FALSE, and it failed in the same shape as the defect it was
# built to prevent, one level deeper:
#
#   round 1  a hand-written predicate enumerated the offenders and matched only
#            the VARIABLE-ASSIGNMENT spelling. Reported 2 sites; there were 4.
#   round 2  the lint written to replace that count was itself a DENYLIST of
#            two source spellings behind a third gate (`cat > …/tmux <<`). A
#            skeptic planted EIGHT idiomatic alternatives; all eight produced a
#            body carrying a gate-3 signature, all eight reached
#            /tmp/tmux-<uid>/default, and the lint passed on all eight. One of
#            them, `TMUX_BIN="$(command -v tmux)"`, differs from the lint's own
#            positive control by TWO QUOTE CHARACTERS.
#
# So the lesson is not "that predicate was too narrow" — it is that A DENYLIST
# OF SPELLINGS INHERITS THE BLIND SPOT OF WHOEVER WROTE IT, and dressing one up
# as a mechanical guard hides that rather than fixing it. The scan now uses an
# ALLOWLIST WITH A DEFAULT-DENY ARM (_tmux_shim_scan.awk), the shape
# `_bookkeeping.sh::bk_pane_kill_authorized` prescribes: a planted body it
# cannot PROVE safe is reported UNSAFE, including via a spelling nobody has
# thought of yet. All eight escapes are pinned below as positive controls.
#
# ── WHAT A GREEN HERE DOES *NOT* CERTIFY ───────────────────────────────────
#
# Stated plainly because overclaiming is precisely what this file got wrong
# twice. The CLASSIFICATION arms are an allowlist; the DISCOVERY is not.
# Since `#1184` discovery is POSITIONAL rather than a shape denylist: a site is
# any line that WRITES a path ending `/tmux` (literally, or through a variable
# assigned such a path in the same file), by any route — a redirection operand
# anywhere on the line, a heredoc attached to such a write, or a write utility
# carrying such a path as an argument. It no longer cares what the command is
# called, which is what the previous four-arm version keyed on.
#
# **THE RESIDUAL IS SMALLER, NOT GONE.** Enumeration is still SYNTACTIC. A target
# assembled at runtime (`t=$D/$n; printf … > "$t"` with `$n` not literal), a
# write through a variable holding the operator, or a path this file never spells
# cannot be resolved by any static read. Those are still NOT SEEN, and their
# absence is still indistinguishable from a pass. What DID change is that an
# unreadable BODY at a discovered site now reaches the default-deny arm instead
# of being silently not-a-site. Variable provenance is followed one level,
# within one file.
#
# That residual is tracked in `#1117` and is why the load-bearing defence is
# NOT this lint: it is `nx_write_tmux_shim`'s RUNTIME refusal, which reads the
# candidate's magic bytes and so cannot be spelled around at all. This lint
# exists to push planting sites onto that writer, not to replace it.
#
# ── AND THE FACT THAT QUALIFIES THE ZERO (your-org/nexus-code#1119, CLOSED) ─
#
# The zero this guard reports is a fact about the CORPUS, not a certification of
# the classifier — and the two are easy to read as one. Measured at `0a10598`
# (working tree clean, so the scan reads exactly that ref) over the 78 non-exempt
# files, 109 sites, command below:
#
#     SAFE-STUB     89   82%
#     SAFE-REALBIN   9    8%
#     SAFE-WRITER    7    6%
#     UNSAFE         4    4%   <- four sites reach the default-deny arm
#
# THIS BLOCK HAS BEEN WRONG TWICE, BOTH TIMES BY CARRYING A NUMBER ACROSS THE
# CHANGE THAT INVALIDATED IT, and both are left described rather than deleted
# because it is this file's own defect class happening inside its own honesty
# section. It said `UNSAFE 0 — NOT ONE SITE REACHES THE DEFAULT-DENY ARM` at
# 7458daf, true when written and false one commit later when routing SAFE-COPY
# to deny (H1c) made the arm reachable. It then said `SAFE-STUB 93 86% /
# UNSAFE 1` at b40b496, which `#1119`'s inversion invalidated in turn.
#
#     for f in $(find monitor -name '*.sh' -type f | sort); do
#         case "$f" in */test-tmux-shim-gate3-safety.sh|*/_tmux-fixture.sh) continue;; esac
#         awk -f monitor/watcher/_tmux_shim_scan.awk "$f"
#     done | cut -d'|' -f2 | sort | uniq -c
#
# WHAT `SAFE-STUB` NOW MEANS, and it is the whole of `#1119`. It used to be
# `is_routing_body` — a DENYLIST of hand-off shapes with a PERMISSIVE default,
# i.e. "I could not find an `exec`" — which is the same shape as the spelling
# denylist this file replaced, one level in, deciding 86% of the corpus. It is
# now `is_mock_body`: POSITIVE PROOF that every simple command in the body is a
# shell keyword, a shell builtin, a function DEFINED IN THE BODY, or a named
# external that cannot execute another program. Anything else falls to
# default-deny. The two escapes `#1119` measured reaching /tmp/tmux-<uid>/default
#
#     export TMUX_BIN=$(command -v tmux)      + a body with no `exec`
#     read -r TMUX_BIN < <(command -v tmux)   + a body with no `exec`
#
# are controls `B/m1` and `B/m2` below, and both are FLAGGED.
#
# THE PATCH THAT WAS REJECTED, AND WHY THE INVERSION IS NOT IT. Treating `"$@"`
# as a hand-off adds 15 UNSAFE across 14 files, one of which
# (`test-paste-followup.sh:94`) is a genuine self-answering mock whose
# `for a in "$@"` is argv INSPECTION. A lint that cries wolf on real mocks gets
# disabled. Under the inversion that exact body classifies MOCK, and it is
# control `B/m5` — the must-NOT-flag half, which is as load-bearing here as the
# escapes.
#
# THE RESIDUAL, NAMED RATHER THAN DEFAULTED. Three of the four UNSAFE sites are
# mocks that invoke `awk`, which is outside the scanner's tier-2 external
# allowlist because it has `system()` and `print | "cmd"`. They are argued
# per-site in EXEMPT_SITES below, with a line-keyed staleness red, rather than
# excused by a permissive arm nobody can see. The fourth is a deliberate copy of
# the wrapper by the suite whose subject IS the wrapper.
#
# The arm-ORDER half of the same family is fixed (deny arms precede every safe
# arm; see classify() in _tmux_shim_scan.awk) and generalised as doctrine in
# `#1121`, whose third property is now in CLAUDE.md.
#
# Run: bash monitor/watcher/test-tmux-shim-gate3-safety.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
MON="$REPO_ROOT/monitor"
SCAN="$_test_dir/_tmux_shim_scan.awk"

# shellcheck source=./_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

# ---------------------------------------------------------------------------
# POPULATION DECLARATION (your-org/nexus-code#1494, #1301 item 2)
# ---------------------------------------------------------------------------
#
# THIS IS A SAFETY GUARD, and on PR #1493 it was one of the two guards
# `ng guards-for-diff` could not see. It returned rc 0 with 28 guards SELECTED
# and green; CI then reddened on this suite and one other, and NEITHER appeared
# in `SELECTED` or in `CONSIDERED AND EXCLUDED`. Declaring no population makes
# a guard INVISIBLE, not excluded, and the two are indistinguishable in the
# output while meaning opposite things. Its failure mode is a fixture client
# reaching the OPERATOR'S REAL tmux BOARD (#1105), so being unroutable is the
# expensive kind of invisible.
#
# THE POPULATION IS SECTION A'S OWN ENUMERATOR — the `find "$MON" -name '*.sh'`
# corpus it classifies — plus the four files it reads by name to reach a
# verdict: the awk classifier that decides SAFE/UNSAFE, the fixture library
# whose `nx_write_tmux_shim` is the prescribed remedy, the assertion library it
# sources, and its own exemption list, which lives INLINE in this file (hence
# no separate manifest path).
#
# ON THE `*.sh` GLOB. It is declared as the guard's ACTUAL boundary, not
# widened here. A glob cannot see `monitor/ng`, and CLAUDE.md is emphatic that
# the most important member of a population is usually the one a glob misses —
# but a population must state what the guard READS, and widening the scan is a
# behavioural change that belongs in its own commit with its own verdict, not
# smuggled in through a declaration. Recorded so the gap is visible rather than
# inherited.
#
# PLACED HERE, above the first thing this suite prints: `gp_handle` EXITS when
# it handles the flag, and anything printed before it lands in the probe's
# stdout and is read as a population row.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    find "$MON" -name '*.sh' -type f | sort
    printf '%s\n' \
        "$SCAN" \
        "$MON/watcher/_tmux-fixture.sh" \
        "$_test_dir/_test_helpers.sh"
}
gp_handle "$@"

EXPECTED_ASSERTIONS=52   # +6: section D, the #1361 digest key   # A=3 + B=40 + C=3, counted BEFORE this census assertion itself
                         # B gained 10 in `#1184`: e1-e6 the six respellings the old shape
                         # denylist could not see, e7c/e7 the single-variable arm-order A/B,
                         # e8 the non-short-circuit, e9 the over-breadth control.
                         # B gained 5 in `#1313`: e10/e11 the two-plant line in both
                         # orders, e12 the per-statement offender name, e13 the
                         # duplicate-record control, e14 the per-site heredoc body.
                         # B gained 2 more on the #1313 skeptic round: e15 the
                         # NON-SITE heredoc payload (a FALSE SAFE), e15c its
                         # unshadowed potency control.
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

command -v awk >/dev/null 2>&1 || { echo "ENV-FAIL: no awk" >&2; exit 1; }
[[ -f "$SCAN" ]] || { echo "ENV-FAIL: scanner missing: $SCAN" >&2; exit 1; }

scan() { awk -f "$SCAN" "$1" 2>/dev/null; }

# ── the exemption key carries a DIGEST of the exempted body (#1361) ─────────
# `<path>:<line>:<sha8>:<reason>`. `_site_digest` is sha1 of the source line's
# exact bytes, first 8 hex; `_exempt_verdict` answers one of
#   exempt              path AND line AND digest match a declared entry
#   exempt-moved:<line> path AND digest match an entry declared at ANOTHER line
#                       (a pure shift — no information, so not a red)
#   body-changed        path AND line match an entry whose digest DIFFERS (the
#                       exempted code changed — the whole claim; LOUD)
#   none                no entry for this site
# Locate by digest; report the line as a hint (warmsk's proposal, adopted).
_site_digest() {   # <file> <line>
    sed -n "${2}p" "$1" 2>/dev/null | sha1sum | cut -c1-8
}
_exempt_verdict() {   # <rel> <line> <digest>
    local rel="$1" ln="$2" dg="$3" e epath eln edg
    local hit_line=""
    while IFS= read -r e; do
        [[ -n "$e" ]] || continue
        epath="${e%%:*}"; [[ "$epath" == "$rel" ]] || continue
        e="${e#*:}"; eln="${e%%:*}"; e="${e#*:}"; edg="${e%%:*}"
        if [[ "$eln" == "$ln" && "$edg" == "$dg" ]]; then printf 'exempt'; return 0; fi
        [[ "$eln" == "$ln" ]] && hit_line="$edg"
        [[ "$edg" == "$dg" ]] && { printf 'exempt-moved:%s' "$eln"; return 0; }
    done <<<"$EXEMPT_SITES"
    if [[ -n "$hit_line" ]]; then printf 'body-changed'; else printf 'none'; fi
}
exempt_moved=''

# ---------------------------------------------------------------------------
echo '=== A: the corpus — every planted shim is PROVABLY safe ==='
# ---------------------------------------------------------------------------
# EXEMPT, by name so a new one cannot join silently:
#   this file            — its positive controls below are DELIBERATE offenders,
#                          planted as test data. (CLAUDE.md: "a failing lint
#                          names its offenders — read the list, not the count";
#                          two of three lines there were the lint's own
#                          fixtures.)
#   _tmux-fixture.sh     — nx_write_tmux_shim's own definition. It cannot be
#                          proven safe STATICALLY because its target is a
#                          parameter; it proves it at RUNTIME by reading the
#                          candidate's magic bytes, which is strictly stronger.
EXEMPT='monitor/watcher/test-tmux-shim-gate3-safety.sh
monitor/watcher/_tmux-fixture.sh'

# EXEMPT SITES — <path>:<line>:<reason>. One entry, and it is a REAL copy of the
# wrapper, correctly flagged: `test-tmux-shim.sh` plants copies of
# monitor/tmuxwrap/tmux ON PURPOSE, to exercise the wrapper's own
# self-recognition (the #1033 mutual re-exec bound). Its SHIM_DIR *is* the
# wrapper directory, so this is the s8 shape written deliberately by the suite
# whose subject IS the wrapper.
#
# Named per-SITE rather than per-FILE so the rest of that file stays covered.
# THE KEY IS `<path>:<line>:<sha8>:<reason>` (your-org/nexus-code#1361). The
# line used to be the whole key, with the rationale "if the site moves the
# excuse stops matching — loud, never silent". That was true and it answered
# the wrong question: it fired on a MOVE (an edit anywhere above the site,
# carrying no information about it — #1348 lost a five-band red to one) and
# was SILENT on a BODY CHANGE (the thing the exemption is a claim about —
# demonstrated by rewriting an exempted mock to `exec` a real tmux, still
# 47/0). The digest inverts the polarity to the correct one: a shift is
# quiet, a body change is loud. Stale entries are still reported (below),
# because an exemption nobody needs is an exemption nobody re-argued.
#
# THE MOCKNESS RESIDUAL (your-org/nexus-code#1119). Three mocks invoke `awk`,
# and `awk` is deliberately OUTSIDE the scanner's tier-2 external allowlist
# because it has `system()` and `print | "cmd"`. Each is argued individually
# rather than defaulted, which is the whole point of the inversion: the arm
# that used to decide these was "I could not find a hand-off", and this list is
# what that arm becomes when it is written down. Re-read the awk program before
# renewing an entry — a `system(` appearing in one of them is the thing that
# makes it wrong.
#
# SEVEN ENTRIES WERE ADDED BY `#1184`, AND THE COUNT IS THE POINT. Inverting
# DISCOVERY did not create seven new hazards; it made seven pre-existing planting
# sites VISIBLE that no arm of the old shape denylist could reach. Every one is
# argued below and every argument was checked against the source, not assumed.
# 4 -> 11 is the measure of how much the old enumeration could not see.
EXEMPT_SITES='monitor/watcher/test-tmux-shim.sh:534:66268d59:deliberate copy of the wrapper; this suite TESTS the wrapper (#1033 self-recognition). TWO records since #1313: the line is `cp ... "$TWO_A/tmux"; cp ... "$TWO_B/tmux"` and the SECOND copy had never been reported by any version of this scanner. The line key covers both.
monitor/watcher/test-bootstrap-recover.sh:385:ac8317c8:mock uses awk+mv on LITERAL single-quoted programs; no system(), no print-to-command, no tmux named anywhere (#1119)
monitor/watcher/test-entry.sh:129:4a67f24b:mock uses awk+sed on LITERAL single-quoted programs; no system(), no e-command, no tmux named anywhere (#1119)
monitor/watcher/test-over-limit.sh:41:792257e6:mock uses awk on a LITERAL single-quoted program; no system(), no print-to-command, no tmux named anywhere (#1119)
monitor/cc-harness/_lib.sh:467:8e8cae0f:DELIBERATE wrapper — the cc-harness socket shadow, which carries NEXUS-PATH-FRONT-WRAPPER-MARKER on purpose so tmuxwrap SKIPS it. It cannot route through nx_write_tmux_shim (that writer refuses a marker-carrying shim by design). Its exec target comes from _cch_real_tmux, whose tier-1 arm skips every script (_cch_is_script) and requires the candidate to answer `-V` as tmux — so the target is a real BINARY by construction, checked at runtime, which is the same defence nx_write_tmux_shim provides (#1184)
monitor/watcher/test-cc-harness-socket-isolation.sh:227:bf9880fd:DELIBERATE wrapper stand-in — reproduces the hostile ambient environment the cc-harness runs in (a PATH-front shim carrying the marker, as \$BASH_ENV arranges). Being flagged is correct; the fixture exists to BE the thing tmuxwrap skips (#1184)
monitor/watcher/test-tmux-shim.sh:581:9f1f0eac:deliberate materialisation of an OLD wrapper copy via `git show`; this suite TESTS the wrapper self-recognition bound, same argument as :534 (#1184)
monitor/watcher/test-tmux-shim.sh:595:333fad38:deliberate SYNTHESIS of a pre-fix wrapper via sed; this suite TESTS the wrapper self-recognition bound, same argument as :534 (#1184)
monitor/watcher/test-pane-state.sh:3080:f347781e:mock uses sed on a LITERAL ANSI-C-quoted program (ANSI-stripping); no e-command, no system(), no tmux named anywhere — same class as the awk entries above (#1184) RE-KEYED 3012 -> 3080 by W2-21 (#1374/#1446 added fixtures above this site); body byte-identical — and since #1361 a pure shift no longer needs a re-key to stay green, so this one is a hint update.
monitor/watcher/test-pane-state.sh:3113:15cc572a:mock uses sed on a LITERAL ANSI-C-quoted program (ANSI-stripping); no e-command, no system(), no tmux named anywhere — same class as the awk entries above (#1184) RE-KEYED 3045 -> 3113 by W2-21 (#1374/#1446 added fixtures above this site); body byte-identical — and since #1361 a pure shift no longer needs a re-key to stay green, so this one is a hint update.
monitor/watcher/test-skeptic-arm-recording.sh:819:ce1c9101:a call-RECORDING mock that routes NOWHERE. Added by 82c66dbe (#1251) at 2026-09-01T23:38:30-07:00, which turned this suite RED on dev. The file it writes is exactly `#!/usr/bin/env bash` / `echo "$*" >> <dir>/tmux.calls` / `exit 0` -- echo is a builtin, exit is a keyword, no tmux is named anywhere, there is no exec and no PATH lookup, so it cannot reach any tmux, let alone the wrapper. What the scanner cannot prove is an artefact of the WRITE SHAPE, not of the body: the target dir arrives as the `%s` FILL of printf, so `$_sb1251` lands in the body text as an unregistered word in command position and the PROVEN-mock arm correctly refuses it. Same class as the awk entries above. PREFERRED FIX, and the one this lint exists to push: route the plant through nx_write_tmux_shim (monitor/watcher/_tmux-fixture.sh), whose runtime magic-byte refusal is strictly stronger than any static verdict -- that change belongs in test-skeptic-arm-recording.sh and this exemption should be deleted when it lands (#1313 bundle). RE-KEYED 723 -> 816 by the W2-16 branch, which added 96 lines above this site; the body is byte-identical and the exemption argument is unchanged. The line-keyed staleness red did exactly its job — it went LOUD when the line moved, which is why this is a re-key and not a silent drift. RE-KEYED 816 -> 819 by the W2-19 bundle (#1370 added three lines above this site); body byte-identical again.
monitor/watcher/test-spawn-fresh-orchestrator.sh:933:811b6e8c:derives a failing stub from test-spawn-fresh-orchestrator.sh:154 by sed. That SOURCE is classified in this same file and scores SAFE-STUB (PROVEN mock), and the sed adds only `new-window) exit 1 ;;`. The scanner follows variable provenance one level but not FILE contents, so it correctly cannot prove this itself (#1184)'

offenders=''; scanned=0; sites=0; exempt_hit=''
while IFS= read -r f; do
    rel="${f#$REPO_ROOT/}"
    case $'\n'"$EXEMPT"$'\n' in *$'\n'"$rel"$'\n'*) continue ;; esac
    out=$(scan "$f") || continue
    [[ -n "$out" ]] || continue
    scanned=$(( scanned + 1 ))
    sites=$(( sites + $(printf '%s\n' "$out" | grep -c .) ))
    bad=''
    while IFS= read -r rec; do
        [[ -n "$rec" ]] || continue
        ln="${rec%%|*}"
        # your-org/nexus-code#1361: the exemption is a claim about the BODY of
        # the exempted line, so the key carries a digest of that body and the
        # verdict is decided by `_exempt_verdict` (below): a pure SHIFT of the
        # line is silent (it carries no information; it cost #1348 a
        # five-band red), a CHANGE to the exempted body is LOUD (it is the
        # whole claim). The line number is kept as a hint and for the
        # staleness check, never as the deciding key.
        _dg=$(_site_digest "$f" "$ln")
        case "$(_exempt_verdict "$rel" "$ln" "$_dg")" in
            exempt)
                exempt_hit+="${exempt_hit:+$'\n'}$rel:$ln"
                continue ;;
            exempt-moved:*)
                # digest matched an entry keyed to another line of this file:
                # the site MOVED. Exempt, and the staleness check below reports
                # the re-key as information rather than as a red.
                exempt_hit+="${exempt_hit:+$'\n'}$rel:$ln"
                exempt_moved+="${exempt_moved:+$'\n'}$rel:$ln (declared at $(_exempt_verdict "$rel" "$ln" "$_dg" | cut -d: -f2))"
                continue ;;
            body-changed)
                rec="$rec|EXEMPTED BODY CHANGED: line $ln of $rel no longer matches the digest its exemption was argued against — re-argue the exemption or route the plant through nx_write_tmux_shim"
                ;;
        esac
        bad+="${bad:+$'\n'}$rec"
    done < <(printf '%s\n' "$out" | grep '|UNSAFE|' || true)
    [[ -n "$bad" ]] && offenders+="${offenders:+$'\n'}$rel"$'\n'"$(printf '%s' "$bad" | sed 's/^/      /')"
done < <(find "$MON" -name '*.sh' -type f | sort)

# A zero must be a MEASURED zero, never a broken discovery (#618, #707).
if (( scanned == 0 || sites == 0 )); then
    fail "A: discovery found ZERO planted shims in $MON — the scan is broken, and a green here would be vacuous"
else
    pass "A: classified $sites planted-shim site(s) across $scanned file(s)"
    if [[ -z "$offenders" ]]; then
        pass "A: every planted shim is provably safe (writer / mock / real-binary / literal path)"
    else
        fail "A: planted tmux shim(s) that cannot be PROVEN to reach a real tmux binary — tmuxwrap's gate-3 skips a shim that names it, so the -L pin is lost and the client reaches the OPERATOR'S BOARD (#1105):"$'\n'"$offenders"$'\n'"      Fix: route the planting through nx_write_tmux_shim (monitor/watcher/_tmux-fixture.sh)."
    fi
fi

# A STALE EXEMPTION IS A CLAIM NOBODY RE-ARGUED. If a named site no longer
# produces the verdict it was excused for, the excuse must go — otherwise the
# list grows monotonically and stops meaning anything, which is the failure the
# summary-honesty ratchet exists to prevent one directory over.
# Since #1361 a site that MOVED (same body, different line) is still exempt —
# it is matched by digest — but its entry is stale on the LINE axis, which is
# reported as information, not as a red: the entry should be re-keyed at
# leisure, and nothing about the exemption's argument has changed.
_want_ex=$(printf '%s\n' "$EXEMPT_SITES" | grep . | cut -d: -f1,2 | sort -u)
_got_ex=$(printf '%s\n' "$exempt_hit" | grep . | sort -u)
if [[ -n "$exempt_moved" ]]; then
    printf '  NOTE: exempt site(s) MOVED (body unchanged — exempt by digest; re-key the line hint when convenient):\n%s\n' "$(printf '%s' "$exempt_moved" | sed 's/^/        /')"
    _want_ex=$(comm -23 <(printf '%s\n' "$_want_ex") <(printf '%s\n' "$exempt_moved" | sed -E 's/^([^ ]+) \(declared at ([0-9]+)\)$/\1/; s/:[0-9]+$//' | while IFS= read -r _m; do printf '%s\n' "$EXEMPT_SITES" | grep -oE "^${_m//./\\.}:[0-9]+" ; done | sort -u))
    _got_ex=$(comm -23 <(printf '%s\n' "$_got_ex") <(printf '%s\n' "$exempt_moved" | sed -E 's/ \(declared at [0-9]+\)$//' | sort -u))
fi
if [[ "$_want_ex" == "$_got_ex" ]]; then
    pass "A: every exempt SITE is still present and still flagged (no stale excuses)"
else
    fail "A: exempt-site list no longer matches the tree — re-argue or delete."$'\n'"      declared:"$'\n'"$(printf '%s' "$_want_ex" | sed 's/^/        /')"$'\n'"      matched:"$'\n'"$(printf '%s' "$_got_ex" | sed 's/^/        /')"
fi

# ---------------------------------------------------------------------------
echo '=== D: the exemption key is a DIGEST of the exempted body (#1361) ==='
# ---------------------------------------------------------------------------
# The line-keyed matcher fired on a MOVE and was silent on a BODY CHANGE.
# Demonstrated on the real tree: an exempted recorder mock rewritten IN PLACE
# to `exec /usr/bin/env tmux "$@"` — the literal opposite of its stated reason
# — stayed 47/0. Driven here against a planted file and a planted EXEMPT_SITES,
# through the same `_exempt_verdict` the corpus loop uses.
D=$(mktemp -d -t nexus-gate3d-XXXXXX)
printf 'line one\nprintf %s > "$sb/tmux"\nline three\n' "'#!/usr/bin/env bash\\necho \"$*\" >> tmux.calls\\nexit 0\\n'" > "$D/site.sh"
_d2=$(_site_digest "$D/site.sh" 2)
_saved_sites="$EXEMPT_SITES"
EXEMPT_SITES="fake/site.sh:2:${_d2}:a recorder mock that routes nowhere"
if [[ "$(_exempt_verdict fake/site.sh 2 "$_d2")" == exempt ]]; then pass "D: path + line + digest match → exempt"; else fail "D: exact match not exempt"; fi
# a pure SHIFT: same body at another line → still exempt, reported as moved
if [[ "$(_exempt_verdict fake/site.sh 9 "$_d2")" == "exempt-moved:2" ]]; then pass "D: same body at another line → exempt-moved (a shift is not information)"; else fail "D: shift verdict: $(_exempt_verdict fake/site.sh 9 "$_d2")"; fi
# the ISSUE's demonstration: rewrite the exempted body to exec a real tmux
sed -i '2s|.*|printf '"'"'#!/usr/bin/env bash\\nexec /usr/bin/env tmux "$@"\\n'"'"' > "$sb/tmux"|' "$D/site.sh"
_d2b=$(_site_digest "$D/site.sh" 2)
if [[ "$_d2b" != "$_d2" ]]; then pass "D: the rewrite changed the digest (control on the probe itself)"; else fail "D: digest did not change on rewrite"; fi
if [[ "$(_exempt_verdict fake/site.sh 2 "$_d2b")" == body-changed ]]; then pass "D: an exempted body rewritten to exec a real tmux → BODY CHANGED, loud"; else fail "D: body change verdict: $(_exempt_verdict fake/site.sh 2 "$_d2b")"; fi
# the OLD key, reconstructed: path:line prefix — it would have exempted the rewrite
if grep -q "^fake/site.sh:2:" <<<"$EXEMPT_SITES"; then pass "D: CONTROL — the old line-only key would have EXEMPTED the rewritten body (the #1361 defect)"; else fail "D: old-key control did not reproduce"; fi
if [[ "$(_exempt_verdict fake/other.sh 2 "$_d2")" == none ]]; then pass "D: an undeclared site is not exempt"; else fail "D: undeclared site verdict wrong"; fi
EXEMPT_SITES="$_saved_sites"
rm -rf "$D"

# ---------------------------------------------------------------------------
echo '=== B: the eight escapes that defeated the previous version ==='
# ---------------------------------------------------------------------------
# Every one of these was measured reaching /tmp/tmux-<uid>/default — the board —
# while the spelling-denylist version reported ALL TESTS PASSED. They are the
# regression test for the claim this file makes about itself.
CTL=$(mktemp -d -t nexus-test-XXXXXX)
trap 'rm -rf "$CTL"' EXIT

plant() {   # plant <name> <content>; returns the file path
    printf '%s\n' "$2" > "$CTL/$1.sh"; printf '%s' "$CTL/$1.sh"
}
expect_unsafe() {
    local name="$1" desc="$2" f="$CTL/$1.sh" out rc
    # CHECK scan's rc EXPLICITLY. The herestring below closes the #622 SIGPIPE
    # race, but capturing into `$out` also discards the producer's exit status —
    # and `scan` is `awk … 2>/dev/null`, so that status was the LAST surviving
    # evidence of an awk fatal error. A scanner that emits correct records and
    # THEN dies would otherwise be caught by nothing here. (The piped form
    # propagated it under pipefail, but could not tell a dead scan from a
    # SIGPIPE'd one on a payload that DOES match — which is the defect being
    # fixed. So: keep the herestring, restore the signal separately.) The
    # corpus loop at :156 already spells it `out=$(scan "$f") || continue`.
    out=$(scan "$f"); rc=$?
    if (( rc != 0 )); then
        fail "B/$name: $desc — scan FAILED (rc $rc); this case proved nothing"
        return
    fi
    if grep -q '|UNSAFE|' <<<"$out"; then pass "B/$name: $desc — FLAGGED"
    else fail "B/$name: $desc — MISSED (this is a board-reaching escape)"; fi
}

plant s0 '#!/usr/bin/env bash
REAL=$(nx_real_tmux_bin)
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
exec env -u TMUX "$REAL" -L "$SOCK" "\$@"
WRAP
' >/dev/null
# Same rc check as expect_unsafe, and an `elif` rather than a bare `||` on
# purpose: a dead scan yields empty output, `grep -q` finds no match, and the
# else arm would otherwise announce this CONTROL as a PASS on no evidence.
s0_out=$(scan "$CTL/s0.sh"); s0_rc=$?
if (( s0_rc != 0 )); then
    fail "B/s0: CONTROL — scan FAILED (rc $s0_rc); the control cannot vouch for the allowlist"
elif grep -q '|UNSAFE|' <<<"$s0_out"; then
    fail "B/s0: CONTROL — a shim built from nx_real_tmux_bin was flagged; the allowlist is over-broad"
else
    pass "B/s0: CONTROL — a shim built from nx_real_tmux_bin is NOT flagged"
fi

plant s1 '#!/usr/bin/env bash
TMUX_BIN="$(command -v tmux)"
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
exec env -u TMUX "$TMUX_BIN" -L "$SOCK" "\$@"
WRAP
' >/dev/null
expect_unsafe s1 'quoted $(command -v tmux) — two quote chars from the old control'

plant s2 '#!/usr/bin/env bash
TMUX_BIN=$(command -v tmux 2>/dev/null)
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
exec "$TMUX_BIN" -L "$SOCK" "\$@"
WRAP
' >/dev/null
expect_unsafe s2 'command -v with a redirect inside the substitution'

plant s3 '#!/usr/bin/env bash
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
exec "$NEXUS_ROOT/monitor/tmuxwrap/tmux" -L "$SOCK" "\$@"
WRAP
' >/dev/null
expect_unsafe s3 'the gate-3 signature written LITERALLY, no substitution at all'

plant s4 '#!/usr/bin/env bash
TB=$(type -p tmux)
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
exec "$TB" -L "$SOCK" "\$@"
WRAP
' >/dev/null
expect_unsafe s4 'type -p rather than command -v'

plant s5 '#!/usr/bin/env bash
TB=$(command -v tmux)
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
"$TB" -L "$SOCK" "\$@"
WRAP
' >/dev/null
expect_unsafe s5 'shim body with NO exec'

plant s6 '#!/usr/bin/env bash
TB=$(command -v tmux)
SHIM="$d/tmux"
cat > "$SHIM" <<WRAP
#!/usr/bin/env bash
exec "$TB" -L "$SOCK" "\$@"
WRAP
' >/dev/null
expect_unsafe s6 'target path held in a VARIABLE (the fifth-site shape)'

plant s7 '#!/usr/bin/env bash
TB=$(command -v tmux)
printf "#!/usr/bin/env bash\nexec %s -L %s \"\$@\"\n" "$TB" "$SOCK" > "$d/tmux"' >/dev/null
expect_unsafe s7 'printf redirect, no heredoc at all'

plant s8 '#!/usr/bin/env bash
cp "$NEXUS_ROOT/monitor/tmuxwrap/tmux" "$d/tmux"' >/dev/null
expect_unsafe s8 'cp of the wrapper itself — no body is written at all'

# --- round 3: two more, both of which the v2 ARM ORDER proved SAFE ------------
plant c1a '#!/usr/bin/env bash
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
"$NEXUS_ROOT/monitor/tmuxwrap/tmux" -L "$SOCK" "\$@"
WRAP
' >/dev/null
expect_unsafe c1a 'wrapper named LITERALLY, no exec — the arm-order escape (#1121)'

plant c2 '#!/usr/bin/env bash
cp "$NEXUS_ROOT/monitor/tmuxwrap/tmux" "$W/bin/tmux"' >/dev/null
expect_unsafe c2 'copy of the wrapper that SAFE-LITERAL excused via its DESTINATION'

# --- the MOCKNESS INVERSION (your-org/nexus-code#1119) -----------------------
# m1/m2 are the two escapes `#1119` MEASURED reaching /tmp/tmux-<uid>/default.
# Both defeat the old one-level `^[ \t]*NAME=` provenance and carry no `exec`,
# so the hand-off denylist answered SAFE-STUB. Under positive proof of mockness
# a variable in command position is not proof, and both fall to default-deny.
plant m1 '#!/usr/bin/env bash
export TMUX_BIN=$(command -v tmux)
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
"$TMUX_BIN" -L "$SOCK" "\$@"
WRAP
' >/dev/null
expect_unsafe m1 'export-prefixed assignment defeats provenance, body has no exec (#1119)'

plant m2 '#!/usr/bin/env bash
read -r TMUX_BIN < <(command -v tmux)
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
"$TMUX_BIN" -L "$SOCK" "\$@"
WRAP
' >/dev/null
expect_unsafe m2 'read-from-process-substitution defeats provenance, no exec (#1119)'

# m3 — an UNLISTED external in command position. `env` takes a command to run,
# which is exactly why it is not in tier 2.
plant m3 '#!/usr/bin/env bash
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
env tmux -L "$SOCK" "\$@"
WRAP
' >/dev/null
expect_unsafe m3 'body invokes an external that can itself run a command (env)'

# m4 — the DEMO.SH SHAPE, one level in: the lookup lives in a FUNCTION, so no
# assignment provenance can see it. `type -P tmux` in this workspace resolves
# monitor/tmuxwrap FIRST (locals-env.sh prepends it), so this writes a shim
# that execs the wrapper. Measured live in monitor/cc-harness/demo.sh:158.
plant m4 '#!/usr/bin/env bash
_rt() { type -P tmux 2>/dev/null || echo /usr/bin/tmux; }
printf "#!/usr/bin/env bash\nexec %q \"\$@\"\n" "$(_rt)" > "$d/tmux"' >/dev/null
expect_unsafe m4 'redirect whose target comes from a PATH lookup inside a FUNCTION (#1119)'

expect_safe() {
    local name="$1" desc="$2" f="$CTL/$1.sh" out rc
    out=$(scan "$f"); rc=$?
    if (( rc != 0 )); then
        fail "B/$name: CONTROL — scan FAILED (rc $rc); the control cannot vouch for anything"
    elif grep -q '|UNSAFE|' <<<"$out"; then
        fail "B/$name: CONTROL — $desc was FLAGGED; the predicate is over-broad and will be disabled"
    elif [[ -z "$out" ]]; then
        fail "B/$name: CONTROL — no record at all; discovery missed the site, so this proves nothing"
    else
        pass "B/$name: CONTROL — $desc is NOT flagged"
    fi
}

# m5 — THE FALSE POSITIVE THAT SANK THE NAIVE FIX. `#1119` rejected adding
# `body ~ /"\$@"/` to the denylist because it flagged test-paste-followup.sh:94,
# a self-answering mock whose `for a in "$@"` is argv INSPECTION, not
# forwarding. This is that body. A lint that cries wolf on its own fixtures
# gets disabled, so the control is as load-bearing as the escapes above.
plant m5 '#!/usr/bin/env bash
cat > "$W/bin/tmux" <<'"'"'STUB'"'"'
#!/usr/bin/env bash
cmd="${1:-}"
if [[ "$cmd" == "list-windows" ]]; then
    fmt=""; prev=""
    for a in "$@"; do [[ "$prev" == "-F" ]] && fmt="$a"; prev="$a"; done
    printf "%s\n" "$fmt"
fi
exit 0
STUB
' >/dev/null
expect_safe m5 'a mock that INSPECTS "$@" without forwarding it'

# m6 — a mock whose fixed output comes from a NESTED heredoc. Reading the
# payload as commands flagged test-paste-dead-pane-guard.sh:804 on the strings
# `$1` and the delimiter itself; the payload is data and is skipped.
plant m6 '#!/usr/bin/env bash
cat > "$W/bin/tmux" <<'"'"'STUB'"'"'
#!/usr/bin/env bash
[[ "$1" == "list-panes" ]] || exit 0
cat <<ROWS
$1
ROWS
STUB
' >/dev/null
expect_safe m6 'a mock emitting fixed output through a nested heredoc'

# m7 — the FIXED demo.sh shape: a redirect whose target is held in a variable
# assigned from nx_real_tmux_bin. The complement of m4; without it, "m4 is
# flagged" would be satisfied by a predicate that flags every redirect.
plant m7 '#!/usr/bin/env bash
_REAL_TMUX=$(nx_real_tmux_bin)
printf "#!/usr/bin/env bash\nexec %q \"\$@\"\n" "$_REAL_TMUX" > "$d/tmux"' >/dev/null
expect_safe m7 'a redirect shim built from nx_real_tmux_bin'

# --- three found by ADVERSARIALLY PROBING THE INVERSION ITSELF ---------------
# The mockness scanner shipped with two holes of exactly the shape `#1119` is
# about, and neither was reachable from the escapes `#1119` listed — m1/m2 are
# caught by the REGISTERED-VARIABLE test, not by the tokeniser, so a hole in the
# tokeniser was invisible behind them. Both were found by hand-probing the new
# predicate rather than by review, which is why the probes are now controls.

# m8 — a variable in command position that is NOT one this file has registered.
# The scanner used to SKIP quoted spans wholesale, so `"$X" "$@"` contained no
# unquoted word at all and answered PROVEN MOCK on finding no commands.
# NOTE THE BODY IS EXACTLY TWO QUOTED WORDS. An earlier draft wrote
# `"$SOME_TMUX" -L "$SOCK" "\$@"`, and that control was VACUOUS: the mutant that
# restores the hole still fails on the bare `-L`, so the assertion passed for a
# reason unrelated to the property it names. Caught by RUNNING the mutant, which
# is the only way that kind of vacuity shows up — a control that passes for the
# wrong reason is this cluster's own defect, inside its own repair.
plant m8 '#!/usr/bin/env bash
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
"$SOME_TMUX" "\$@"
WRAP
' >/dev/null
expect_unsafe m8 'an UNREGISTERED variable in command position, quoted'

# m9 — a command substitution inside a DOUBLE-QUOTED argument. `printf` is a
# builtin, so the line reads as a mock unless `$(` is understood to reopen code.
plant m9 '#!/usr/bin/env bash
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
printf "%s" "$(tmux -V)"
WRAP
' >/dev/null
expect_unsafe m9 'a command substitution inside a double-quoted argument'

# m10 CONTROL — a tmux SHORT format alias in a case pattern. `strip_comment`
# protected `#{…}` and not `#I`, so ` #W'"'"')` was eaten as a trailing comment,
# leaving an UNTERMINATED quote that swallowed the rest of the body and produced
# a confident wrong offender on three genuine mocks (test-respawn.sh:101, :713,
# test-spawn-fresh-orchestrator.sh:154).
plant m10 '#!/usr/bin/env bash
cat > "$W/bin/tmux" <<'"'"'WRAP'"'"'
#!/usr/bin/env bash
case "$2" in
    '"'"'#I #W'"'"')  printf '"'"'%d %s\n'"'"' 0 alpha ;;
    *)         printf '"'"'%s\n'"'"' alpha ;;
esac
WRAP
' >/dev/null
expect_safe m10 'a mock whose case pattern is a tmux SHORT format alias'

# m11 — a `<<` INSIDE A STRING must not be read as a heredoc opener. The nested
# heredoc skip is not quote-aware, and a naive skip-until-delimiter drops EVERY
# REMAINING LINE when the delimiter never arrives — turning a routing shim into
# a proven mock on the strength of text it never executed. The routing line is
# BELOW the decoy on purpose: that is the line the swallow would eat.
plant m11 '#!/usr/bin/env bash
cat > "$W/bin/tmux" <<WRAP
#!/usr/bin/env bash
echo "a << b"
"$SOME_TMUX" "\$@"
WRAP
' >/dev/null
expect_unsafe m11 'a `<<` inside a string does not swallow the rest of the body'

# m12 — `redirect_body()` ITSELF, and the plant is NOT MINE. Supplied by the
# `#1175` skeptic (`vacevidsk`), which found the function LOAD-BEARING BUT
# UNPINNED: removing it changed no verdict on any of the 109 corpus sites and was
# invisible to all 29 assertions, so mutant 2 — recorded in the PR as a red —
# SURVIVES at head. `B/m4` cannot witness it: that plant is UNSAFE under both
# readings for DIFFERENT reasons (`$(_rt)` reaches a command position on the
# whole line too), and `expect_unsafe` pins the VERDICT and never the REASON.
#
# This plant discriminates because it is a ROUTING SHIM WRITTEN BY A BUILTIN:
# with `redirect_body` the body is the shim's own text and `exec` denies it;
# without, the body is the writing LINE, `printf` is a builtin and sets sawword,
# and the whole thing reads as a PROVEN MOCK. That is this file's own stated
# justification for the function, reproduced as a green.
#
# Using the skeptic's plant verbatim rather than one of my own is the point: a
# guard pinned only by fixtures its author wrote is pinned by the same blind spot
# that let the gap open.
plant m12 '#!/usr/bin/env bash
printf "#!/usr/bin/env bash\nexec \"$MYTM\" \"$@\"\n" > /opt/bin/tmux' >/dev/null
expect_unsafe m12 'a routing shim written by printf — redirect_body is what sees it'


# UNSAFE IS NOT ENOUGH WHEN THE POINT IS THAT THE BODY WAS READ. Every e-case
# below plants the SAME hazard (`command -v tmux` resolved at write time), so the
# correct record names that signature. A record reading `could not PROVE …
# (default-deny)` is also UNSAFE and would satisfy a bare `expect_unsafe` — and
# does: with continuation folding disabled, e1's second physical line is a
# LEADING redirect in its own right, so the site is still discovered and still
# denied, on a body the scanner never read. The assertion passed under a mutant
# that broke exactly what it exists to pin, which is this repo's own inert-
# control failure (#1304) inside a test written to prevent it. So the detail is
# part of the assertion.
expect_unsafe_because() {
    local name="$1" needle="$2" desc="$3" f="$CTL/$1.sh" out rc
    out=$(scan "$f"); rc=$?
    if (( rc != 0 )); then
        fail "B/$name: $desc — scan FAILED (rc $rc); this case proved nothing"
    elif ! grep -q '|UNSAFE|' <<<"$out"; then
        fail "B/$name: $desc — MISSED (this is a board-reaching escape)"
    elif ! grep -qF "$needle" <<<"$out"; then
        fail "B/$name: $desc — flagged, but NOT for reading the body: expected '$needle', got:"$'\n'"$out"
    else
        pass "B/$name: $desc — FLAGGED, and for the right reason"
    fi
}

# ── ENUMERATION IS POSITIONAL (your-org/nexus-code#1184) ────────────────────
#
# `#1119` inverted the BODY question and left the SITE question a FOUR-ARM SHAPE
# DENYLIST WITH A PERMISSIVE DEFAULT — `nx_write_tmux_shim`, `cat > … <<`,
# line-leading `printf|echo` with `>`, line-leading `cp|install|ln`. A line
# matching none of them was NOT A SITE, silently, and every allowlist below it
# was unreachable. These are the respellings MEASURED invisible at `703483b5`,
# each a semantics-preserving rewrite of the m-series controls above that they
# would otherwise be identical to. They are pinned here so the inversion cannot
# be quietly narrowed back.
#
# `expect_unsafe` is itself the discovery assertion: a missed site produces NO
# record, so `grep -q '|UNSAFE|'` fails and the case reports MISSED. An absence
# cannot pass here.
plant e1 '#!/usr/bin/env bash
printf "#!/bin/sh\nexec %s \"\$@\"\n" "$(command -v tmux)" \
    > "$D/tmux"' >/dev/null
expect_unsafe_because e1 'resolves tmux through PATH at write time' 'redirect on a CONTINUATION line (#1184)'

plant e2 '#!/usr/bin/env bash
tee "$D/tmux" <<EOF
#!/bin/sh
exec $(command -v tmux) "\$@"
EOF
' >/dev/null
expect_unsafe_because e2 'resolves tmux through PATH at write time' 'a write utility that is not `cat` (#1184)'

plant e3 '#!/usr/bin/env bash
> "$D/tmux" printf "#!/bin/sh\nexec %s \"\$@\"\n" "$(command -v tmux)"' >/dev/null
expect_unsafe_because e3 'resolves tmux through PATH at write time' 'LEADING redirection — nothing line-leading to key on (#1184)'

plant e4 '#!/usr/bin/env bash
cp "$(command -v tmux)" "$D/tmux"  # a trailing comment displaces the target' >/dev/null
expect_unsafe_because e4 'resolves tmux through PATH at write time' 'a trailing comment displacing the end-anchored target (#1184)'

plant e5 '#!/usr/bin/env bash
cat <<EOF > "$D/tmux"
#!/bin/sh
exec $(command -v tmux) "\$@"
EOF
' >/dev/null
expect_unsafe_because e5 'resolves tmux through PATH at write time' 'redirect AFTER the heredoc opener — same utility, operands swapped (#1184)'

# THE SIXTH, and it is the one that was never written down: a COMPOUND GROUP
# redirected as a whole. It is the most idiomatic planting shape in this tree —
# THREE live sites use it (test-cc-harness-socket-isolation.sh:227,
# test-pane-state.sh:3012 and :3045) — and it matched none of the four old arms.
plant e6 '#!/usr/bin/env bash
{
    printf "#!/usr/bin/env bash\n"
    printf "exec %s \"\$@\"\n" "$(command -v tmux)"
} > "$D/tmux"' >/dev/null
expect_unsafe_because e6 'resolves tmux through PATH at write time' 'a COMPOUND GROUP redirected as a whole (#1184)'

# ── AND THE ARM-ORDER DEFECT, WHICH #1184 DOES NOT NAME (#1121 one pass up) ──
#
# Pass 2's `nx_write_tmux_shim` arm was a bare SUBSTRING search that `continue`d
# the line: a permissive SAFE arm returning before every DENY arm — exactly the
# shape `#1121` fixed inside classify(), left standing one level above it, where
# it decides whether classify() runs AT ALL.
#
# e7/e7c is a SINGLE-VARIABLE A/B. The two plants differ by the eight characters
# of a comment. Measured at `703483b5`: the control scored `UNSAFE|copy: body
# names the wrapper LITERALLY` and e7 scored `SAFE-WRITER` — the single most
# direct expression of the hazard, pronounced safe by a COMMENT. Both must now
# be UNSAFE, and the control is here so the pair cannot both pass by the site
# simply never being discovered.
plant e7c '#!/usr/bin/env bash
cp "$WRAP/tmuxwrap/tmux" "$D/tmux"' >/dev/null
expect_unsafe_because e7c 'names the wrapper LITERALLY' 'CONTROL — a literal wrapper copy, no comment (#1184)'

plant e7 '#!/usr/bin/env bash
cp "$WRAP/tmuxwrap/tmux" "$D/tmux" # nx_write_tmux_shim' >/dev/null
expect_unsafe_because e7 'names the wrapper LITERALLY' 'the SAME copy, plus a comment naming the writer — must not flip (#1121/#1184)'

# The arm must also stop SHORT-CIRCUITING: a line that genuinely calls the writer
# AND plants a shim some other way has to report both, or the real call becomes a
# licence for whatever shares its line.
plant e8 '#!/usr/bin/env bash
nx_write_tmux_shim "$D"; printf "exec %s \"\$@\"\n" "$(command -v tmux)" > "$D/tmux"' >/dev/null
e8_out=$(scan "$CTL/e8.sh"); e8_rc=$?
if (( e8_rc != 0 )); then
    fail "B/e8: scan FAILED (rc $e8_rc); this case proved nothing"
elif grep -q '|SAFE-WRITER|' <<<"$e8_out" && grep -q '|UNSAFE|' <<<"$e8_out"; then
    pass "B/e8: a writer call does not shadow a plant sharing its line — BOTH reported"
else
    fail "B/e8: the writer arm still short-circuits its line; got:"$'\n'"$e8_out"
fi

# CONTROL for the widened enumeration. Discovery got broader, so the question
# "is it now over-broad?" has to be asked with a plant that MUST come back
# clean — otherwise every case above is satisfied by a scanner that flags
# everything. A compound-group MOCK is the exact shape e6 attacks, minus the
# hand-off.
plant e9 '#!/usr/bin/env bash
{
    printf "#!/usr/bin/env bash\n"
    printf "case \"\$1\" in list-windows) echo win ;; *) exit 0 ;; esac\n"
} > "$D/tmux"' >/dev/null
expect_safe e9 'a compound-group MOCK — widened discovery is not a widened verdict'

# --- #1313: ENUMERATION must not return on the line's first route ------------
# `site_route()` resolved the line's write routes and RETURNED on the first
# match, which is #1121's shape one level further out again — in ENUMERATION,
# where #1184 had just fixed it in CLASSIFICATION. A SAFE-capable route that
# returns first makes every DENY route behind it on that line unreachable.
#
# THIS WAS LIVE, NOT LATENT. `#1313` reports zero live instances; re-measured at
# `5bd6d400` the corpus holds one — `test-tmux-shim.sh:534`,
# `cp "$SHIM_DIR/tmux" "$TWO_A/tmux"; cp "$SHIM_DIR/tmux" "$TWO_B/tmux"` — whose
# SECOND copy no version of this scanner had ever reported.
#
# Each of e10-e12 and e14 is a POTENCY control in its own right: run against the
# pre-fix scanner every one of them reports ONE record where two are due.
_two_sites() {   # _two_sites <name> <desc>; assert exactly two records
    local name="$1" desc="$2" out rc n
    out=$(scan "$CTL/$name.sh"); rc=$?
    if (( rc != 0 )); then
        fail "B/$name: $desc — scan FAILED (rc $rc); this case proved nothing"; return 1
    fi
    n=$(printf '%s\n' "$out" | grep -c .)
    printf '%s' "$out"
    (( n == 2 )) || { fail "B/$name: $desc — expected 2 records, got $n:"$'\n'"$out"; return 1; }
    return 0
}

plant e10 '#!/usr/bin/env bash
cp "$W/tmuxwrap/tmux" "$D/tmux"; printf "exit 0\n" > "$D/tmux"' >/dev/null
e10_out=$(_two_sites e10 'two plants on one line, hazardous FIRST') || :
if [[ -n "$e10_out" ]] \
   && grep -q 'UNSAFE|copy: body names the wrapper LITERALLY' <<<"$e10_out" \
   && grep -q 'SAFE-STUB' <<<"$e10_out"; then
    pass "B/e10: two plants on one line — the redirect does not shadow the wrapper copy (#1313)"
elif [[ -n "$e10_out" ]]; then
    fail "B/e10: enumeration still returns on the line's first route; got:"$'\n'"$e10_out"
fi

# The ORDER is the whole variable in `#1313`'s repro, so reverse it. Measured:
# the pre-fix scanner reports ONE record in BOTH orders — reversing only changes
# WHICH plant is invisible, which is why the fix is to stop choosing rather than
# to choose better.
plant e11 '#!/usr/bin/env bash
printf "exit 0\n" > "$D/tmux"; cp "$W/tmuxwrap/tmux" "$D/tmux"' >/dev/null
e11_out=$(_two_sites e11 'two plants on one line, hazardous SECOND') || :
if [[ -n "$e11_out" ]] \
   && grep -q 'UNSAFE|copy: body names the wrapper LITERALLY' <<<"$e11_out" \
   && grep -q 'SAFE-STUB' <<<"$e11_out"; then
    pass "B/e11: the SAME pair, order reversed — still BOTH reported (#1313)"
elif [[ -n "$e11_out" ]]; then
    fail "B/e11: enumeration is order-dependent; got:"$'\n'"$e11_out"
fi

# A RECORD MUST BE ABOUT THE STATEMENT IT NAMES. The copy arm was handed the
# whole LINE as its body, so a `tmuxwrap` in a NEIGHBOUR command convicted this
# one — red for the right reason by accident, naming the wrong statement
# (`#1210`). Two copies, only the first hazardous: the details must DIFFER.
# This attacks the fix on an axis `#1313` never used.
plant e12 '#!/usr/bin/env bash
cp "$W/tmuxwrap/tmux" "$D/tmux"; cp "$S/tmux" "$E/tmux"' >/dev/null
e12_out=$(_two_sites e12 'two copies on one line') || :
if [[ -n "$e12_out" ]] \
   && grep -q 'UNSAFE|copy: body names the wrapper LITERALLY' <<<"$e12_out" \
   && grep -q 'UNSAFE|copy: source not resolved' <<<"$e12_out"; then
    pass "B/e12: two copies on one line — each verdict is about its OWN statement (#1210/#1313)"
elif [[ -n "$e12_out" ]]; then
    fail "B/e12: the copy body is still the whole LINE, so the offender name is the line's; got:"$'\n'"$e12_out"
fi

# CONTROL for the widened ENUMERATION, the exact counterpart of e9's control for
# the widened DISCOVERY. Per-command enumeration must not manufacture a second
# record where there is one plant — a scanner that emits duplicates satisfies
# every case above and is useless.
e13_out=$(scan "$(plant e13 '#!/usr/bin/env bash
printf "exit 0\n" > "$D/tmux"')"); e13_rc=$?
e13_n=$(printf '%s\n' "$e13_out" | grep -c .)
if (( e13_rc != 0 )); then
    fail "B/e13: CONTROL — scan FAILED (rc $e13_rc); the control cannot vouch for anything"
elif (( e13_n == 1 )) && grep -q 'SAFE-STUB' <<<"$e13_out"; then
    pass "B/e13: CONTROL — ONE plant still yields exactly ONE record (#1313)"
else
    fail "B/e13: CONTROL — per-command enumeration is duplicating records ($e13_n); got:"$'\n'"$e13_out"
fi

# TWO HEREDOCS ON ONE LINE. `TK_HDELIM` is the LINE's FIRST delimiter, so every
# site on the line read the FIRST heredoc's body — the second site would be
# classified on payload that is not its own. The payloads follow in delimiter
# order, so the cursor must ADVANCE past each body it consumes. Mutating the
# cursor back to a fixed start makes site 2 re-read site 1's hazardous body and
# turns this SAFE-STUB into UNSAFE.
plant e14 '#!/usr/bin/env bash
cat <<'"'"'A'"'"' > "$D/tmux"; cat <<'"'"'B'"'"' > "$E/tmux"
exec "$WRAPDIR/tmuxwrap/tmux" "$@"
A
exit 0
B' >/dev/null
e14_out=$(_two_sites e14 'two heredocs on one line') || :
if [[ -n "$e14_out" ]] \
   && grep -q 'UNSAFE|heredoc: body names the wrapper LITERALLY' <<<"$e14_out" \
   && grep -q 'SAFE-STUB|heredoc' <<<"$e14_out"; then
    pass "B/e14: two heredocs on one line — each site reads its OWN body (#1313)"
elif [[ -n "$e14_out" ]]; then
    fail "B/e14: heredoc payloads are not walked in order; got:"$'\n'"$e14_out"
fi

# A HEREDOC ATTACHED TO A NON-SITE COMMAND STILL CONSUMES A PAYLOAD, and the
# first form of the #1313 walk did not consume it — the cursor advanced only
# when a SITE took a body, so a later site began reading at the wrong offset.
#
# THIS FAILED TOWARD A FALSE SAFE, which is the one direction the gate above
# cannot catch: the corpus check keys on `|UNSAFE|`, so a shim scored SAFE is
# invisible to it. Found by the #1313 skeptic pass. The payload below is
# arranged so the SITE's delimiter appears INSIDE the non-site payload, which
# truncates the site's body to the benign `exit 0` and leaves its real body —
# a literal wrapper exec — unread.
#
# The expectation is verified against the SHELL, not against the scanner: run
# the same text and the bytes at "$D/tmux" are `exec …/tmuxwrap/tmux "$@"`.
plant e15 '#!/usr/bin/env bash
cat <<'"'"'A'"'"' > "$D/notmux"; cat <<'"'"'B'"'"' > "$D/tmux"
exit 0
B
A
exec "$W/tmuxwrap/tmux" "$@"
B' >/dev/null
e15_out=$(scan "$CTL/e15.sh"); e15_rc=$?
if (( e15_rc != 0 )); then
    fail "B/e15: scan FAILED (rc $e15_rc); this case proved nothing"
elif grep -q 'UNSAFE|heredoc: body names the wrapper LITERALLY' <<<"$e15_out"; then
    pass "B/e15: a NON-SITE heredoc's payload is consumed, so the site reads its OWN body (#1313 F3)"
else
    fail "B/e15: a non-site heredoc payload is being absorbed — the site was classified on somebody else's body, and it scored SAFE; got:"$'\n'"$e15_out"
fi

# POTENCY CONTROL FOR e15, and it is the reason e15 is not vacuous: the SAME
# body under a site whose delimiter is NOT shadowed must come back UNSAFE too,
# so e15 cannot be satisfied by a scanner that simply denies every heredoc.
plant e15c '#!/usr/bin/env bash
cat <<'"'"'B'"'"' > "$D/tmux"
exec "$W/tmuxwrap/tmux" "$@"
B' >/dev/null
e15c_out=$(scan "$CTL/e15c.sh")
if grep -q 'UNSAFE|heredoc: body names the wrapper LITERALLY' <<<"$e15c_out"; then
    pass "B/e15c: CONTROL — the same body, unshadowed, is UNSAFE for the SAME reason"
else
    fail "B/e15c: CONTROL — the unshadowed form does not flag; e15 proves nothing. got:"$'\n'"$e15c_out"
fi



# ---------------------------------------------------------------------------
echo '=== C: the runtime refusal, which is the load-bearing defence ==='
# ---------------------------------------------------------------------------
# The lint pushes planting sites onto nx_write_tmux_shim; the writer is what
# actually cannot be fooled, because it reads the candidate's magic bytes
# rather than its spelling. Pin the two to each other so they cannot drift.
. "$MON/watcher/_tmux-fixture.sh"
real=$(nx_real_tmux_bin) || real=""
if [[ -z "$real" ]]; then
    fail "C: nx_real_tmux_bin found no real tmux BINARY on PATH"
else
    m=$(head -c2 "$real")
    if [[ "$m" == '#!' ]]; then fail "C: nx_real_tmux_bin returned a SCRIPT, not a binary"
    else pass "C: nx_real_tmux_bin returns a real binary (magic bytes, not a name)"; fi
    # The wrapper is CONSTRUCTED here, never borrowed from $PATH. Borrowing made
    # this block's assertion COUNT an environment property: on this host two
    # tmux wrappers (monitor/tmuxwrap, the agent-sandbox shim) precede
    # /usr/bin/tmux, so `command -v tmux` differed from nx_real_tmux_bin and all
    # three C assertions ran; on CI the only tmux IS the real binary, the two
    # compared EQUAL, and the refusal case — the load-bearing defence this block
    # exists to pin — was not exercised at all. The census caught the shortfall
    # (28 ran, 29 declared) and turned every PR's CI red while every local run
    # stayed green, because the branch is unreachable wherever a wrapper is
    # installed. Constructing the wrapper makes the refusal run EVERYWHERE, so
    # CI now actually covers the defence instead of recording a hole in it, and
    # the declared count stops depending on what happens to be on $PATH
    # (your-org/nexus-code#1262).
    #
    # A `#!` script is the whole of what nx_write_tmux_shim refuses — it reads
    # the candidate's magic bytes, not its spelling — so a two-line exec wrapper
    # is the same class of input as the real tmuxwrap, and it exists on every
    # host.
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real" > "$CTL/wrapper-tmux"
    chmod +x "$CTL/wrapper-tmux"
    if nx_write_tmux_shim "$CTL/out" "$CTL/wrapper-tmux" sock 2>/dev/null; then
        fail "C: nx_write_tmux_shim ACCEPTED a wrapper — the load-bearing defence is gone"
    else
        pass "C: nx_write_tmux_shim REFUSES a wrapper-built shim, by magic bytes"
    fi
    if nx_write_tmux_shim "$CTL/out" "$real" sock 2>/dev/null; then
        pass "C: CONTROL — it accepts the real binary"
    else
        fail "C: CONTROL — it refused the real binary; the writer is unusable"
    fi
fi

_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    pass "D: assertion census — $_total assertions ran, $EXPECTED_ASSERTIONS declared"
else
    fail "D: assertion census — $_total assertions ran, $EXPECTED_ASSERTIONS declared"
fi

th_summary_and_exit
