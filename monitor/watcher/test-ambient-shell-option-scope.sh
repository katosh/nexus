#!/usr/bin/env bash
# test-ambient-shell-option-scope.sh — shell options are invisible ambient
# state, and this suite gates the two directions they travel in
# (your-org/nexus-code#721).
#
# ambient-shell-option-scope: allow-unconditional-unset  this file BUILDS
# fixtures that write both banned idioms into a temp root, so its own source
# text contains them by construction. Exempted by MARKER rather than by
# filename: a filename exemption silently covers whatever else is later named
# that way, and #655's marker lesson is that an exemption must carry a reason
# or it is indistinguishable from an oversight.
#
# ---------------------------------------------------------------------------
# WHY A GUARD AND NOT A SWEEP
# ---------------------------------------------------------------------------
#
# #721's mechanism: a library relies on a shell option for a correctness
# property and sets it in its own scope; the test file that exercises it also
# has that option on; so it is on either way, deleting it from the library
# changes nothing the suite can see, and the assertion written for the
# mechanism is measuring the harness's settings instead.
#
# Measured on this tree, the mechanism is currently DORMANT everywhere, and
# the reason is structural rather than lucky:
#
#   * exactly ONE test file sets a shell option ambiently — an unpaired
#     top-level `shopt -s`, test-pane-state.sh — and that file SOURCES NOTHING.
#     It runs pane-state.sh as an executable, and shopt state does not cross a
#     process boundary.
#   * every other setter in the corpus is a scoped `-s`/`-u` pair.
#
# So the intersection {sets an option ambiently} x {sources a library that
# scopes that option} is EMPTY. A `shopt -s` whose deletion changes nothing
# observable is NOT automatically a defect — most of the dormant sites are
# correct defensive scoping, and deleting them would be a behaviour change
# with no defect to justify it. What IS a defect is an assertion that
# measures the harness instead of the library, and that becomes possible the
# moment the intersection stops being empty.
#
# The remedy for a dormant population is therefore not to sweep it. It is to
# hold the emptiness that keeps it dormant, so no future test can promote a
# site to live in silence — which is exactly how this class went undetected
# long enough to be filed, rewritten twice, and refuted once.
#
# ---------------------------------------------------------------------------
# WHAT EACH PROPERTY MEASURES, AND ON WHICH AXIS ITS BOUNDARY IS DRAWN
# ---------------------------------------------------------------------------
#
# P1 (masking; harness -> library). No test file may BOTH set a shell option
#    ambiently AND source a library that scopes that same option.
#
#    STATED EXACTLY, because the sentence above must not be wider than what
#    this holds — a bound drawn on the wrong axis is honest, tested, and false.
#    As shipped in #766 the honest statement was much narrower: *no test file
#    may set a GLOB-FAMILY option ambiently on a LINE-ANCHORED `shopt -s` and
#    DIRECTLY source a library scoping it.* Four gaps, found by the depth-1
#    skeptic on #766, filed as your-org/nexus-code#770 and CLOSED here — plus a
#    FIFTH found while checking the fix's own boundary, below. Each has a
#    fixture that is reachable ONLY through its gap, so reverting any one fix
#    reddens exactly that fixture and nothing else (measured by mutation):
#
#      * TRANSITIVE sourcing was out of reach (the substantive one). Six test
#        files reach the `nullglob`-scoping `_idle_probe.sh` only through an
#        intermediate library; any of them growing an ambient setter went live
#        with P1 silent. Now a fixed point over the source graph.
#      * The `$( … )` collapse was single-LEVEL, so the three nested source
#        lines this repo actually contains parsed as `X` or `..`. Now run to a
#        fixed point.
#      * The option axis was a glob-family LIST, so `patsub_replacement` (the
#        option `_test_helpers.sh` itself manipulates), `lastpipe`,
#        `nocasematch` and `inherit_errexit` were invisible to P1. Now DERIVED
#        per file, as P2's population already was.
#      * The setter count was line-anchored, so `[[ cond ]] && shopt -s
#        nullglob` was not counted — erring toward NOT flagging, the unsafe
#        direction. Now anchored on COMMAND position over comment-stripped
#        text; the comment strip is not optional, because unanchoring alone
#        reads this repo's own prose about `shopt -s` as code.
#      * (the fifth, not in #770) A source path held in a VARIABLE — `.
#        "$HELPERS"` — carries no basename, so the edge was missing from the
#        graph OUTRIGHT, not merely shortened: 75 of this tree's 510 source
#        tokens. Found by sanity-checking a "none of these occur here" sentence
#        in the BOUNDARY note below against a known total; the sentence was
#        wrong. Now resolved against a same-file assignment where one exists
#        (57 of the 62 bare-`$VAR` tokens).
#
#    None of the five was live on this tree when #770 was filed — that was
#    measured, not assumed — and the tree is still quiet under the widened
#    envelope, which is now a much stronger statement than it was.
#
# P2 (leak; library -> caller). No SOURCED library may restore a shell option
#    with an unconditional `shopt -u`, which hands the caller the option OFF
#    however it had it. The correct form is in-tree at watcher/main.sh:
#    `_restore=$(shopt -p <opt>)` … `eval "$_restore"`.
#
#    P2's population is the axis the MECHANISM varies on, and it is DERIVED
#    from the tree rather than listed. A leak crosses a FUNCTION RETURN, not a
#    process boundary — so a script nothing sources cannot leak to anybody,
#    whatever its tail looks like, and four of #721's eight listed `shopt -u`
#    sites are inert for exactly that reason (`install-claude-local.sh`,
#    `upload-asset.sh`, `ng` x2 — none is sourced anywhere in this tree).
#    Listing them as exceptions would rot; deriving the population means that
#    the day somebody adds `source install-claude-local.sh`, that file enters
#    the gated set on its own. Test 6 pins that behaviour, because a boundary
#    that is merely asserted in a comment is the failure mode #721 rewrite 1
#    shipped.
#
# BOUNDARY, stated where a reader hits it: both properties are read from
# SOURCE TEXT by counting, not by executing the shell's scope rules. A `-s`
# guarded by an `if` and a `-u` on the unconditional path counts as paired and
# is not flagged. The counting errs toward flagging (more sets than unsets =>
# ambient), which is the safe direction for a guard, and the fixtures below
# pin both the firing and the quiet cases so "the lint said nothing" is a
# claim about the lint, not about the tree.
#
# WHAT THE WIDENED VERSION STILL CANNOT SEE, enumerated rather than left for
# the next skeptic to find — the whole point of #770 is that a guard whose
# header outruns its reach is worse than a narrow one:
#
#   * A DYNAMIC option name (`shopt -s "$opt"`) is not an option name to the
#     option derivation. Errs toward NOT flagging; zero occurrences in this
#     tree, measured.
#   * A source path in a variable resolves iff the variable is assigned a
#     LITERAL path somewhere in the SAME FILE. That — not "out of reach without
#     executing the shell" — is the axis, and getting it wrong the first time is
#     the second false boundary sentence this note has carried (#778 skeptic,
#     F1). The earlier wording was self-consistent and false: it filed `$NG`
#     under "loop variables and inherited env" when `test-skeptic-channel.sh:29`
#     assigns it a literal path, and `$ENVSH;` under "shapes no single
#     assignment defines" when `test-locals-env.sh:15` assigns exactly that.
#     Both are now resolved. What genuinely remains outside is a variable whose
#     value no literal assignment in the file supplies — a loop variable over a
#     glob (`$init`), a path built in a caller (`$NEXUS_PREV_BASH_ENV`), a
#     mutant path composed at runtime (`$mutant`). Those DO need the shell.
#     Errs toward NOT flagging. **This bullet is no longer load-bearing**: the
#     residue is enumerated into `aso-unresolved-sources.manifest` and P3 fails
#     when it changes, so a wrong sentence here now reds a test instead of
#     misinforming a reader. Measured 2026-08-07: 19 tokens of 577.
#
#     SEVENTEEN of the nineteen genuinely need the shell — `$init` (loop
#     variable over a glob), `${NEXUS_PREV_BASH_ENV}` (inherited env),
#     `<(sed …)` (a process substitution, not a variable at all), and
#     `$1`/`$0`/`$2` (positional parameters, in helpers that source whatever
#     path the caller passes). The other two are named rather than folded in,
#     because "every one of them genuinely needs the shell" is what I wrote
#     first and it was false — F1's shape a fourth time, caught by `#799`'s
#     skeptic (F-2):
#
#       * `watcher/_service_health.sh  $SERVICE_HEALTH_LABSH_EVIDENCE` is
#         STATICALLY RESOLVABLE and is not resolved. The default is supplied by
#         `: "${VAR:=<literal>}"` on a DIFFERENT LINE from the source
#         statement, and `_aso_var_sourced` matches `VAR=` only — `:=` inside
#         `${…}` is neither that nor the inline `${VAR:-default}` the tokeniser
#         rewrites (which is why `nexus-request:130` DID resolve). Left
#         unresolved deliberately rather than special-cased at the last minute:
#         the edge is P2-harmless (the target is already in the sourced-anywhere
#         set via three literal-path sourcings) and a resolver widening belongs
#         in a change that can be reviewed on its own. Recorded here so the
#         manifest is not read as "these all need the shell".
#       * `watcher/test-spawn-pathfront.sh  .zshrc\n` is a `printf`'d line of
#         shell code — DATA, not a source statement. Errs toward flagging, the
#         declared safe direction.
#
#     A systematic sweep of all nineteen found these are the only two; the
#     other `${…:-}` occurrences are emptiness tests, not path defaults.
#
#     THE MANIFEST'S OWN BOUND, which went unstated until your-org/nexus-code#793
#     and is the reason that issue exists. The residue is a residue OF TOKENS.
#     A source statement the TOKENISER never tokenises produces no token, so it
#     **cannot appear in the manifest by construction** — the manifest is
#     structurally blind to precisely what it misses, and its entries read as
#     "these are all that is unresolved" when the true claim is "these are all
#     that is unresolved AMONG STATEMENTS THE TOKENISER SAW." That bound was
#     load-bearing and hidden: the tokeniser was LINE-ANCHORED — the third site
#     of the gap-4 class in this file, inside the very `sed` expression `#791`
#     edited — and 51 real source statements were absent from the graph
#     entirely. Fixed at `_aso_source_tokens`, and the bound that REMAINS is
#     now pinned as data by the P3a shape fixture rather than left in this
#     paragraph, because prose cannot be made to fail.
#   * `_aso_code` tracks `'` and `"` but not backticks or `$'…'`, so a `#`
#     inside one of those would truncate the line early. Errs toward NOT
#     flagging. Measured across all 16 files in the tree that contain a
#     `shopt`: zero lines lose one to anything but a genuine comment opener.
#   * A `shopt -s` inside a QUOTED STRING that also contains a command
#     separator IS counted, because the strip deliberately leaves string data
#     alone. Errs toward flagging. Pinned by test-fixture-quoted-setter.sh.
#   * Two files sharing a basename are scanned as the UNION, since the graph's
#     currency is basenames. Errs toward flagging.
#
# Three of those five err toward NOT flagging, which is the unsafe direction,
# so they are named here rather than left for the next skeptic. None reaches a
# verdict on this tree today, and the real-tree scans below are what re-check
# that on every CI run rather than trusting this paragraph.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_self_dir/../.." && pwd)

MARKER='ambient-shell-option-scope: allow-unconditional-unset'

# --- scanners --------------------------------------------------------------
# Each takes a ROOT so the fixtures below can be scanned by the very same code
# that scans the real tree. A lint proved only against the tree it was written
# for has no known sensitivity.

# THE POPULATION — derived, not listed (your-org/nexus-code#792).
#
# This used to read `find … \( -name '*.sh' -o -name 'ng' \)`, and `#792` was
# filed about that line specifically. `#791` added the `-o -name 'ng'` arm to
# close the single node its own live finding needed — `monitor/ng` leaking
# `nullglob` to a real caller — and in doing so wrote a ONE-ELEMENT ALLOWLIST
# into the file whose header argues, three sections above, that a list rots and
# a derivation does not. It stayed blind to the other TEN extensionless shell
# files under `monitor/`, four of which (`shellenv/.zsh*`) are the PATH-front
# wrapper's own plumbing.
#
# `monitor/shell-files.sh` is now the one answer, shared with both cc-harness
# kill guards and `early-exit-readers.sh`. What matters is not that it sees
# `ng`: it is that the TWELFTH extensionless executable is covered without
# anybody remembering, which `watcher/test-shell-files.sh` proves by planting a
# file under a name that appears nowhere in this repo.
_aso_shf_lib=$(cd "$_self_dir/.." && pwd)/shell-files.sh
[[ -r "$_aso_shf_lib" ]] || {
    echo "missing $_aso_shf_lib (your-org/nexus-code#792)" >&2; exit 1; }
# shellcheck source=/dev/null
. "$_aso_shf_lib"

# Newline-separated, because every consumer below feeds these into a
# `while IFS= read -r` and this tree has no path containing whitespace —
# asserted rather than assumed, by test-shell-files.sh.
_aso_shell_files() { shf_find0 "$1" shell | tr '\0' '\n' | grep -v '^$' | sort; }

# Files a scan should treat as test files / as production files.
#
# `_aso_test_files` stays a NAME glob on purpose: "is this a test file" is a
# question about this repo's naming CONVENTION, which is genuinely a list, and
# not a question about what interprets the file. Only the shell-ness question
# is shared.
_aso_test_files()  { find "$1" -name 'test-*.sh' -type f 2>/dev/null | sort; }
_aso_prod_files()  { _aso_shell_files "$1" | grep -v '/test-'; }

# CODE ONLY. A `#` at a word boundary and outside quotes opens a comment, and
# everything after it is PROSE. This is load-bearing the moment the setter
# regex stops being line-anchored (gap 4 below): this repo discusses
# `shopt -s nullglob` in a dozen comments, and an unanchored count reads those
# as setters. test-pending-decisions.sh:521 alone — a comment quoting the
# idiom — would tip a perfectly balanced file into "ambient" and red the tree.
# Same word-boundary rule as cc-harness/_tmux_kill_scan.awk's strip_comment,
# and for the same reason: a `#` mid-word is data, not a comment opener.
_aso_code() {
    awk '{
        sq = 0; dq = 0; out = ""
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c == "\047" && !dq) sq = !sq
            else if (c == "\"" && !sq) dq = !dq
            else if (c == "#" && !sq && !dq \
                     && (i == 1 || substr($0, i-1, 1) ~ /[[:space:]]/)) break
            out = out c
        }
        print out
    }' "$1" 2>/dev/null
}

# `shopt` in COMMAND position — line start, or after a separator, or after a
# compound-command keyword. This REPLACES the old `^[[:space:]]*` anchor, which
# could not see a top-level `[[ cond ]] && shopt -s nullglob` (your-org/nexus-code#770
# gap 4) and so erred toward NOT flagging, the unsafe direction for a guard.
# Anchoring rather than simply dropping the anchor is what keeps `--shopt -s`
# and a `shopt -s` sitting inside a longer word out of the count.
_ASO_CMD='(^|[;&|(){}]|(^|[[:space:]])(then|do|else|elif)[[:space:]])[[:space:]]*'

# One shopt COMMAND, up to the next separator. Bounding the tail keeps the
# occurrence count honest on a line carrying two commands — `…; then shopt -s
# nullglob; else shopt -u nullglob; fi` must read as one set AND one unset, not
# as one greedy match apiece.
_aso_shopt_re() {   # <s|u> <opt>
    local flag; case "$1" in s) flag='-s' ;; *) flag='-[up]' ;; esac
    printf '%sshopt([[:space:]]+-[a-zA-Z]+)*[[:space:]]+%s[[:space:]][^;&|(){}]*\\b%s\\b' \
        "$_ASO_CMD" "$flag" "$2"
}

_aso_count() {   # <file> <s|u> <opt> -> how many shopt commands do that
    local out
    out=$(_aso_code "$1" | grep -oE "$(_aso_shopt_re "$2" "$3")") || out=
    if [[ -z "$out" ]]; then printf '0'; else printf '%s\n' "$out" | wc -l; fi
}

# Option names this file NAMES in a shopt command. DERIVED, not listed
# (your-org/nexus-code#770 gap 3): the old axis was the six glob-family options, so
# `patsub_replacement` — the option `_test_helpers.sh` itself manipulates, and
# the one that already cost this repo a bash-5.2 debugging round — plus
# `lastpipe`, `nocasematch` and `inherit_errexit` were outside P1 entirely.
# Deriving is the same argument the header already makes for P2's population:
# a list of options rots, and the day somebody scopes one nobody enumerated it
# enters the axis on its own instead of being silently exempt.
_aso_opt_names() {
    _aso_code "$1" \
        | grep -oE 'shopt([[:space:]]+-[a-zA-Z]+)*([[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*)+' \
        | sed -E 's/^shopt//; s/[[:space:]]+-[a-zA-Z]+//g' \
        | tr -s '[:space:]' '\n' | grep -E '^[a-z_][a-z_0-9]*$' | sort -u
}

# Options a file sets more often than it unsets => left on for the rest of it.
_aso_ambient_opts() {
    local f="$1" opt
    grep -q 'shopt' "$f" 2>/dev/null || return 0     # most files, cheaply
    while IFS= read -r opt; do
        [[ -n "$opt" ]] || continue
        (( $(_aso_count "$f" s "$opt") > $(_aso_count "$f" u "$opt") )) \
            && printf '%s\n' "$opt"
    done < <(_aso_opt_names "$f")
    return 0
}

# Basenames this file sources. The `$( … )` collapse is not cosmetic: a
# `. "$(dirname "$0")/lib/x.sh"` contains SPACES inside the path expression, so
# a naive "first whitespace-free token" read returns `"$(dirname` and the
# library is never seen — the scan then reports a clean tree because it looked
# at nothing. That is the silent-zero shape this whole suite is about, and it
# is why the fixtures below source their libraries that way on purpose.
#
# The collapse runs to a FIXED POINT (`:a … ta`), innermost first, because a
# single pass is single-LEVEL and a nested `$( … $( ) … )` still mangles
# (your-org/nexus-code#770 gap 2). Three real sites hit it and all three are now
# resolved correctly — measured, not asserted:
#
#   _channel_lib.sh:32            `X`  -> `_fm_lib.sh`
#   cc-restart-watchdog-loop.sh:61 `X` -> `_log-mode.sh`
#   hooks/gh-write-guard.sh:67    `..` -> `_log-mode.sh`
#
# `..` is the worse of the two failure shapes: it passes the basename filter,
# so the scan carried a confident non-answer rather than nothing. No verdict on
# this tree depended on either — both libraries entered P2 by other single-level
# lines and neither carries a `shopt` — but the fixtures pinned only the
# single-level form while the nested form is what the repo actually contains,
# which was a fair "fitted to the bug that was found" charge. It is paid below.
# The trailing `[;&|)]` strip is not cosmetic. `. "$ENVSH"; . "$ENVSH"` yields
# the token `$ENVSH;` — separator attached — which then fails the bare-`$VAR`
# test below and lands in the "not resolvable" bucket for a reason that has
# nothing to do with being dynamic. Two real tokens (`test-locals-env.sh:194`,
# `:231`) were excluded exactly that way, and the BOUNDARY note called them
# "shapes no single assignment defines" when the same file assigns `ENVSH` a
# literal path at :15 (your-org/nexus-code#778 skeptic, F1).
#
# COMMAND POSITION, not line start (your-org/nexus-code#793(a)). This reader was
# the THIRD site of the gap-4 class in this file, and the worst-placed: it sat
# in the very `sed` expression `#791` edited — that commit added the
# trailing-separator strip above and left the `^[[:space:]]*` anchor untouched —
# under a header that had just finished arguing for "one definition of command
# position in this file, not two."
#
# THERE WERE FOUR, and the count is worth getting right because getting it
# wrong is the defect. `#793` said three; fixing those three, I wrote *"There
# were three. It is now one"* here — and `#799`'s skeptic found a FOURTH
# (F-1) in `aso_scan_leaks`, one function away, still line-anchored. So the
# sentence claiming the class was closed was itself a false boundary sentence,
# in the paragraph closing that class, in the PR arguing prose cannot be made
# to fail. That is the third time this file has carried such a sentence and the
# first time one was written by the fix.
#
# All four now anchor on `$_ASO_CMD`, plus `$_ASO_SRC_CMD` — one strengthening
# of it, argued for below because `.` is one punctuation character rather than
# a word. Two constants, four call sites, and no site with a hand-rolled
# anchor. The claim is deliberately phrased as what is CHECKABLE — the
# `test-fixture-*` cases below and P2's own detector both fire on separator
# forms — rather than as "the class is now closed", which is what I got wrong.
#
# What the anchor could not see, measured on this tree with this code:
#
#     . lib.sh                        -> lib.sh
#     x=1; . lib.sh                   -> (nothing)
#     [[ -f f ]] && . lib.sh          -> (nothing)
#     if x; then . lib.sh; fi         -> (nothing)
#
# 526 line-anchored statements against 726 in command position: **200 source
# statements were absent from the graph entirely**, not shortened. The filed
# issue put the number at 18; 18 is the count of statements on lines carrying
# no line-anchored source at all, and it undercounts because the old reader was
# also ONE-TOKEN-PER-LINE — `sed -nE …p` prints one substitution per line, so
# `. "$ENVSH"; . "$ENVSH"; . "$ENVSH"` contributed a single token. Both are
# fixed here: `grep -oE` returns every occurrence.
#
# Not exotic shapes, either. The two commonest are the guarded source —
#     [[ -r "$_script_dir/_pane-live.sh" ]] && . "$_script_dir/_pane-live.sh"
#     [[ -f "$SCRIPT_DIR/locals-env.sh" ]]  && . "$SCRIPT_DIR/locals-env.sh"
# — and the `bash -c '…; . "$2"; …'` probe shape the test corpus is full of.
#
# The comment strip is not optional here, for the same reason it is not
# optional for the setter count: unanchored from line start, this repo's own
# prose about `. lib.sh` reads as code.
#
# ONE ANCHOR OR TWO? `_ASO_SRC_CMD` is `_ASO_CMD` with one strengthening — the
# separator must be followed by WHITESPACE — and introducing a second constant
# in a file whose header demands one needs a reason better than taste. It has
# one, and the reason is that `.` is not a word.
#
# `shopt` is five characters; a separator immediately before it (`;shopt -s x`)
# is unambiguous. The `.` builtin is ONE PUNCTUATION CHARACTER, and it collides
# with two things this repo is full of:
#
#     printf '  reachable network). Or bind loopback…'    <- English full stop
#     jq 'select(. != "")'                                <- jq identity filter
#
# Both put a `.` directly after `)` or `(`, and the plain anchor read them as
# source statements. Measured: with `_ASO_CMD`, the residue gained eleven
# entries that were not source statements at all (`Usage:`, `!=`, `==`, `+`,
# `Recorded.\n`, `Release:`, …), which is a manifest full of noise — and a
# noisy manifest gets regenerated without being read, which is the failure mode
# this whole mechanism exists to prevent. A real `. lib.sh` always carries
# whitespace or a line start before the dot; a sentence terminator never does.
#
# ERRS TOWARD NOT FLAGGING, which is the unsafe direction, so it is named:
# `x=1;. lib.sh` is legal shell and is NOT seen. Measured on this tree: zero
# occurrences, and re-measured by the source-shape fixture on every run rather
# than trusted from this paragraph.
#
# `${VAR:-<literal>}` IS resolved, by the substitution in the tokeniser below,
# and that is a finding this mechanism produced against its own author. Widening
# the reader surfaced `client/nexus-request:130` —
#
#     . "${NEXUS_WATCH_LIB:-$_wl_dir/_nexus_watch_lib.sh}"
#
# — as the token `_nexus_watch_lib.sh}`, trailing brace attached, which lands in
# the residue for a reason that has nothing to do with being dynamic. That is
# F1's shape for the THIRD time: a statically-resolvable path sitting in the
# "genuinely needs the shell" bucket. The manifest's own regeneration note asks
# exactly this question of any new entry, and the answer here was "resolvable",
# so it is resolved rather than recorded. Both client tools reach
# `_nexus_watch_lib.sh` this way, and both edges were absent from the graph.
_ASO_SRC_CMD='(^[[:space:]]*|[;&|(){}][[:space:]]+|(^|[[:space:]])(then|do|else|elif)[[:space:]]+)'
# The token body excludes separators (`[^[:space:];&|)]+`) rather than taking
# any run of non-space and stripping a trailing `;` afterwards. That is not a
# tidy-up of the old strip — it is load-bearing for the multi-statement line
# that motivated it. `grep -oE` matches NON-OVERLAPPING, so a greedy
# `[^[:space:]]+` swallows the `;` that the NEXT match needs as its
# command-position anchor, and `. "$ENVSH"; . "$ENVSH"; . "$ENVSH"` yields two
# tokens instead of three. The trailing strip below is kept as defence in
# depth; with this class it is a no-op on every shape in the tree.
_aso_source_tokens() {
    _aso_code "$1" \
        | sed -E ':a; s/\$\([^()]*\)/X/g; ta' \
        | grep -oE "${_ASO_SRC_CMD}(\.|source)[[:space:]]+[^[:space:];&|)]+" \
        | sed -E 's@^.*(^|[;&|(){}[:space:]])(\.|source)[[:space:]]+@@' \
        | sed -E 's@\$\{[A-Za-z_][A-Za-z0-9_]*:?[-=]([^}]*)\}@\1@g' \
        | sed -E 's@.*/@@; s@["'"'"'`]@@g; s@[;&|)]+$@@' \
        | grep -v '^$'
}

# A token that is a BARE `$VAR` carries no basename, so the filter above drops
# it and the edge vanishes ENTIRELY — a strictly larger hole than gap 1's, which
# only lost depth. Not a corner either: `. "$HELPERS"`, `. "$NG"`, `. "$ENVSH"`
# and friends. Measured over this tree with this code, 2026-08-07:
#
#     510 source tokens = 435 literal + 62 bare `$VAR` + 13 other non-literal
#     of the 62, 57 resolve from a same-file assignment; 5 do not
#
# Found by sanity-checking a "no dynamic source paths occur here" sentence in
# the BOUNDARY note against a known total. The sentence was wrong — #770's own
# method applied to #770's own fix. Resolve the variable against a LITERAL
# assignment of it in the same file and take the basename.
#
# THREE THINGS THIS GOT WRONG FIRST TIME ROUND, all found by #778's skeptic and
# all fixed here, because the first version drew its own boundary in the wrong
# place and then wrote a sentence defending it:
#
#   * The assignment was matched LINE-ANCHORED (`^[[:space:]]*`) — literally the
#     gap-4 anchor, re-instantiated inside the gap-5 fix, in the same commit
#     that removed it from `_aso_ambient_opts` a hundred lines above. So
#     `d=$(dirname "$0"); LIB="$d/lib/x.sh"`, `[[ -d /tmp ]] && LIB=…`,
#     `export LIB=…` and `if true; then LIB=…; fi` all resolved to nothing. Now
#     anchored on `$_ASO_CMD`, the same command-position constant gap 4 uses —
#     one definition of "command position" in this file, not two.
#   * `export` and `readonly` were missing beside `local`/`declare`.
#   * The basename had to end in `.sh`/`.zsh`/`.bash`, so `NG="…/monitor/ng"`
#     never resolved — even though `ng` is a first-class node of this graph
#     (`_aso_index` enumerates via `_aso_shell_files`). `monitor/ng` itself
#     scopes `nullglob` and reaches five further basenames, so
#     `test-skeptic-channel.sh`'s ENTIRE source graph was absent, not shortened.
#     Now the value's first token is collapsed, unquoted and reduced to its
#     basename, which admits extensionless nodes without enumerating suffixes.
#
# A value that is not a path yields a basename matching no file, so it
# contributes no edge; several assignments of one name are unioned. Both err
# toward FLAGGING, the declared safe direction.
# THE BREAK HOOK (your-org/nexus-code#793(b)).
#
# P3's guards exist to stop a resolver broken into resolving EVERYTHING from
# agreeing with a manifest regenerated from that same broken resolver. As
# shipped, they did not: every one of them measured a stage ADJACENT to the
# resolver, so emptying the residue satisfied all of them and the suite passed
# with a 0-token manifest. A guard that has never been observed failing is not
# evidence — the sibling tmux lint says exactly this about itself and runs a
# negative control first.
#
# So the break is now a first-class, in-suite operation rather than something a
# skeptic has to hand-patch to discover. `_ASO_BREAK_RESOLVER=1` makes every
# dynamic token resolve, which is precisely the failure being guarded against,
# and P3 below RUNS it and asserts the guards go red. This is the difference
# between "we wrote three guards" and "the guards bite".
#
# Note what it does NOT do: it returns a basename matching no real file, so the
# source GRAPH is unchanged and P1/P2 keep their verdicts. A cruder break (one
# that returns a bogus resolution for every token, real ones included) is caught
# incidentally by four P1 gap fixtures, which would have masked the vacuity
# rather than demonstrated it.
_aso_var_sourced() {   # <file> <newline-separated dynamic tokens>
    if [[ -n "${_ASO_BREAK_RESOLVER:-}" ]]; then
        printf 'BROKEN_RESOLVER_SENTINEL.sh\n'; return 0
    fi
    local f="$1" code tok v
    # Same `$( … )` fixed-point collapse the source-line reader uses: without it
    # `LIB="$(dirname "$0")/lib/x.sh"` has a SPACE inside the value and the
    # first-token read returns `"$(dirname`.
    code=$(_aso_code "$f" | sed -E ':a; s/\$\([^()]*\)/X/g; ta')
    while IFS= read -r tok; do
        v=$(printf '%s\n' "$tok" | sed -nE 's/^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$/\1/p')
        [[ -n "$v" ]] || continue
        printf '%s\n' "$code" \
            | grep -oE "${_ASO_CMD}(local|declare|typeset|export|readonly)?([[:space:]]+-[a-zA-Z]+)*[[:space:]]*$v=[^[:space:];&|]*" \
            | sed -E "s@.*[[:space:]]?$v=@@; s@[\"'\`]@@g; s@.*/@@" \
            | grep -E '^[A-Za-z0-9_.-]+$'
    done <<<"$2"
    return 0
}

_aso_sourced_by_file() {
    local toks lit dyn
    toks=$(_aso_source_tokens "$1")
    [[ -n "$toks" ]] || return 0          # the common case: sources nothing
    lit=$(printf '%s\n' "$toks" | grep -E '^[A-Za-z0-9_.-]+$') || lit=
    dyn=$(printf '%s\n' "$toks" | grep -E '^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$') || dyn=
    { [[ -n "$lit" ]] && printf '%s\n' "$lit"
      [[ -n "$dyn" ]] && _aso_var_sourced "$1" "$dyn"; } | sort -u
    return 0
}

# --- the RESIDUE, pinned as a manifest rather than described in prose --------
# Twice now this file has carried a BOUNDARY sentence that was honestly held,
# self-consistent, and false — first "no dynamic source paths occur here" (78
# tokens said otherwise), then "the residue is out of reach without executing
# the shell" (three statically-resolvable shapes said otherwise, #778 skeptic
# F1). A third would be a pattern, not an accident.
#
# Prose cannot be made to fail. So the excluded set is now DATA: every source
# token that contributes no graph edge is enumerated here and recorded in
# `aso-unresolved-sources.manifest`, and P3 below fails when the two disagree —
# in either direction. Widen the resolver and it reds (regenerate, and say what
# you resolved); add a new unresolvable shape and it reds (decide whether it is
# genuinely shell-dependent, or another thing hiding behind a principled-sounding
# sentence). Same contract as `early-exit-readers.manifest`.
#
# Regenerate with:
#   bash monitor/watcher/test-ambient-shell-option-scope.sh --emit-unresolved \
#       > monitor/watcher/aso-unresolved-sources.manifest
# LC_ALL=C on the sort, and the sort applied to the OUTPUT rather than to the
# file list. Without it this manifest is host-specific: `en_US.utf8` collation
# ignores a leading `_`, so `monitor/_node-bootstrap.sh` sorts among the `n`s
# while `C` puts it first — and CI runs under C. That reddened all six unit
# cells on the first push of this PR with a diff of exactly two transposed
# lines and identical content.
#
# This repo had already paid for the identical trap once:
# `early-exit-readers.sh:190` documents it in the same words, and
# `test-early-exit-reader-manifest.sh:241` pins it with a C-vs-en_US.utf8
# equivalence assertion. I copied the manifest pattern without copying its
# guard, which is its own small instance of this PR's theme — the mechanism was
# there to be reused and I reimplemented the part around it instead.
_aso_unresolved_sources() {   # <root> -> "<relpath>\t<token>" per line
    local root="$1" f tok
    {
        while IFS= read -r f; do
            while IFS= read -r tok; do
                [[ -n "$tok" ]] || continue
                case "$tok" in *[!A-Za-z0-9_.-]*) ;; *) continue ;; esac
                [[ -n "$(_aso_var_sourced "$f" "$tok")" ]] && continue
                printf '%s\t%s\n' "${f#"$root"/}" "$tok"
            done < <(_aso_source_tokens "$f")
        done < <(_aso_shell_files "$root")
    } | LC_ALL=C sort
    return 0
}

# Total source tokens — the TOKENISER's output, one stage upstream of the
# resolver. Necessary but nowhere near sufficient; see `_aso_p3_verdicts`.
_aso_source_token_total() {   # <root>
    local root="$1" f tok n=0
    while IFS= read -r f; do
        while IFS= read -r tok; do [[ -n "$tok" ]] && n=$(( n + 1 )); done \
            < <(_aso_source_tokens "$f")
    done < <(_aso_shell_files "$root")
    printf '%s' "$n"
}

# --- P3's non-vacuity guards, as a FUNCTION of the thing they judge ----------
#
# your-org/nexus-code#793(b). The guards used to be four assertions written
# inline against the live residue, and all four passed against a residue that
# was EMPTY because the resolver had been broken into agreement — 25 of 25
# green with a 0-token manifest. Each measured a stage adjacent to the resolver
# instead of the resolver's own discrimination:
#
#   | guard as shipped        | what it measured   | why emptiness satisfied it |
#   | population floor >= 400 | the TOKENISER      | breaking the resolver does not shrink the token count |
#   | `$NG` absent            | an ABSENCE         | absent-because-empty, not absent-because-resolved |
#   | C == en_US.utf8         | two orderings      | two empty sets are trivially equal |
#   | manifest matches        | recorded vs live   | 0 == 0 |
#
# The control was the sharpest instance: written to prove the residue's
# emptiness-of-`$NG` was EARNED, and satisfied by the residue being empty.
#
# Two changes fix that. First, at least one guard is now POSITIVE — an
# assertion emptiness CANNOT satisfy — and the residue itself is floored rather
# than only the population it is drawn from. Second, and more important, the
# guards are a FUNCTION of (residue, total) rather than inline assertions, so
# the suite can evaluate them against a DELIBERATELY BROKEN residue and assert
# they go red. A guard whose failure has never been observed is a claim, not
# evidence; this makes the failure observable on every run.
#
# Prints `<name>=<ok|BROKEN>` per guard. Never fails; the caller adjudicates.
_aso_p3_verdicts() {   # <residue-text> <token-total>
    local residue="$1" total="$2" n
    n=$(printf '%s\n' "$residue" | grep -c . )

    # (1) The TOKENISER's population. Necessary — a residue drawn from nothing
    #     says nothing — but explicitly NOT sufficient, which is the whole
    #     finding: this number is unmoved by any resolver break.
    (( total >= 450 )) && echo "population=ok" || echo "population=BROKEN"

    # (2) POSITIVE, and the one that does the work. The RESOLVER's own output
    #     must be non-empty. A resolver that resolves everything reds here, and
    #     no amount of adjacent-stage health can paper over it.
    (( n >= 10 )) && echo "residue-floor=ok" || echo "residue-floor=BROKEN"

    # (3) POSITIVE, and specific. `$init` is a loop variable over a glob: no
    #     literal assignment in its file supplies it, so it can NEVER resolve
    #     from source text and MUST be in the residue. An empty residue fails
    #     this by construction — which is exactly what the old `$NG` control
    #     could not do, because it was shaped as an absence.
    grep -qF '$init' <<<"$residue" \
        && echo "positive-unresolvable=ok" || echo "positive-unresolvable=BROKEN"

    # (4) The old control, KEPT — but it is only meaningful in the presence of
    #     (2) and (3). `$NG` has a literal assignment at
    #     `test-skeptic-channel.sh:29`, so a resolver that discriminates must
    #     leave it OUT. Alone it is vacuous; alongside a floored, positively
    #     populated residue it pins the other direction of the discrimination.
    grep -qF '$NG' <<<"$residue" \
        && echo "control-resolvable=BROKEN" || echo "control-resolvable=ok"
}

# Regeneration mode. Deliberately BEFORE the fixtures below, so emitting the
# manifest neither builds nor scans a temp tree.
if [[ "${1:-}" == --emit-unresolved ]]; then
    _aso_unresolved_sources "$(cd "$_self_dir/.." && pwd)"
    exit 0
fi

# --- the source graph, resolved TRANSITIVELY --------------------------------
# P1 asks whether a test file's ambient option kills a `shopt -s` in a library
# it ENDS UP RUNNING, and sourcing composes: a file that sources `_a.sh` which
# sources `_idle_probe.sh` runs `_idle_probe.sh` in its own shell exactly as a
# direct `. _idle_probe.sh` would. Reading DIRECT source lines only
# (your-org/nexus-code#770 gap 1, the substantive one) left SIX test files reaching the
# `nullglob`-scoping `_idle_probe.sh` at depth >= 2 and invisible to P1 —
# test-coldbuild-guard.sh (3), test-service-log-mode.sh (2),
# watcher/test-clone-drift.sh (3), watcher/test-fs-guard.sh (3),
# watcher/test-version-restart{,-self}.sh (3). Each is a site the guard would
# have let go live in silence, which is the one thing it exists to stop.
#
# Resolved as a fixed point over BASENAMES — the currency `_aso_sourced_by_file`
# already returns and the one P2's population already uses. A basename mapping
# to several paths is scanned as the union, which errs toward FLAGGING. Cycles
# terminate because a basename is enqueued at most once.
#
# The index replaces a `find "$root" -name "$lib"` that used to run inside a
# triple loop, which is why the WIDER scan is also the faster one: 13.0s user
# against the depth-1 version's 11.0s for a strictly larger analysis, and 36s
# wall against its 71s. Stated precisely, because the obvious reading of
# "built once" is wrong: each `aso_scan_*` call is a COMMAND SUBSTITUTION, so
# it indexes in its own subshell and the cache never reaches the parent — the
# index is built once per (root x scan), i.e. four times per run, not once.
# The caching that does bite is within a scan, across its 277 test files.
declare -A _ASO_SRC=() _ASO_PATHS=()
_ASO_INDEXED=

_aso_index() {   # <root>
    [[ "$_ASO_INDEXED" == "$1" ]] && return 0
    _ASO_SRC=(); _ASO_PATHS=()
    local f b
    while IFS= read -r f; do
        b=${f##*/}
        _ASO_PATHS[$b]="${_ASO_PATHS[$b]:-}$f"$'\n'
        _ASO_SRC[$f]=$(_aso_sourced_by_file "$f")
    done < <(_aso_shell_files "$1")
    _ASO_INDEXED="$1"
    return 0
}

# Every basename reachable from <file> by sourcing, at ANY depth.
_aso_reachable() {   # <root> <file>
    _aso_index "$1"
    local -A seen=()
    local -a queue=()
    local b p n i=0
    while IFS= read -r b; do
        [[ -n "$b" && -z "${seen[$b]:-}" ]] && { seen[$b]=1; queue+=("$b"); }
    done <<<"${_ASO_SRC[$2]:-}"
    while (( i < ${#queue[@]} )); do
        b=${queue[i]}; i=$(( i + 1 ))
        printf '%s\n' "$b"
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            while IFS= read -r n; do
                [[ -n "$n" && -z "${seen[$n]:-}" ]] && { seen[$n]=1; queue+=("$n"); }
            done <<<"${_ASO_SRC[$p]:-}"
        done <<<"${_ASO_PATHS[$b]:-}"
    done
    return 0
}

# Every basename sourced by ANYTHING under the root — the derived population.
# Read off the same index P1 walks, so the two properties cannot drift on what
# "sourced" means — including on the gap-2 and gap-5 resolutions, which P2's
# population now inherits for free.
_aso_sourced_anywhere() {
    _aso_index "$1"
    local f
    for f in "${!_ASO_SRC[@]}"; do printf '%s\n' "${_ASO_SRC[$f]}"; done \
        | grep -E '^[A-Za-z0-9_.-]+$' | sort -u
}

_aso_scopes_opt() {   # <file> <opt>
    (( $(_aso_count "$1" s "$2") > 0 ))
}

# P1 violations: "<testfile>:<opt>:<lib>" per line.
aso_scan_masking() {
    local root="$1" t opt lib libpath
    _aso_index "$root"
    while IFS= read -r t; do
        grep -qF "$MARKER" "$t" && continue
        while IFS= read -r opt; do
            [[ -n "$opt" ]] || continue
            while IFS= read -r lib; do
                [[ -n "$lib" ]] || continue
                while IFS= read -r libpath; do
                    [[ -n "$libpath" ]] || continue
                    _aso_scopes_opt "$libpath" "$opt" \
                        && printf '%s:%s:%s\n' "${t#"$root"/}" "$opt" "$lib"
                done <<<"${_ASO_PATHS[$lib]:-}"
            done < <(_aso_reachable "$root" "$t")
        done < <(_aso_ambient_opts "$t")
    done < <(_aso_test_files "$root")
    return 0
}

# P2 violations: "<file>:<line>:<text>" per line, SOURCED files only.
aso_scan_leaks() {
    local root="$1" f hit
    local sourced; sourced=$(_aso_sourced_anywhere "$root")
    while IFS= read -r f; do
        grep -qF "$MARKER" "$f" && continue
        # Whole-line membership WITHOUT a pipe. `printf … | grep -qxF` would be
        # the obvious spelling and is a live bug here, not a style nit: this
        # file runs under `set -o pipefail`, `grep -q` exits on its FIRST
        # match, the writer takes SIGPIPE, and pipefail surfaces 141 — so
        # `|| continue` fires on a file that DID match and the scan silently
        # under-reports. It survives locally because the list fits the pipe
        # buffer; `test-sigpipe-assertion-lint.sh` is what caught it. A
        # silent under-count in the population is exactly the failure this
        # suite exists to gate, so it does not get to live inside it.
        [[ $'\n'"$sourced"$'\n' == *$'\n'"$(basename "$f")"$'\n'* ]] || continue
        while IFS= read -r hit; do
            [[ -n "$hit" ]] && printf '%s:%s\n' "${f#"$root"/}" "$hit"
        # COMMAND POSITION, not line start — the FOURTH site of the gap-4 class
        # in this file, found by #799's skeptic (F-1) inside P2's own detector,
        # one function away from where this PR closed the third. Line-anchored,
        # `x=1; shopt -u nullglob` and `if true; then shopt -u extglob; fi` were
        # invisible to P2, erring toward NOT flagging — the unsafe direction.
        #
        # Zero live instances at the time of the fix (measured over P2's real
        # population; the only tree hits are in `test-*` files, which
        # `_aso_prod_files` excludes, and are conditional set/unset pairs). So
        # this was latent — which is exactly how the other three survived, and
        # is not a reason to leave the fourth.
        #
        # `_aso_code` first: unanchored, this repo's own prose about `shopt -u`
        # reads as code, the same way it does for the setter count.
        done < <(_aso_code "$f" \
                   | grep -nE "${_ASO_CMD}shopt([[:space:]]+-[a-zA-Z]+)*[[:space:]]+-u[[:space:]]" \
                   2>/dev/null)
    done < <(_aso_prod_files "$root")
    return 0
}

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
#
# What this guard READS, so `monitor/guards-for-diff.sh` can tell a worker that
# its diff entered this population before CI does. Declared by calling the
# guard's OWN enumerator — `_aso_shell_files`, the same function P1 and P2 scan
# through — because a hand-typed copy would drift and then confidently report
# that this suite does not read a file it does read.
#
# The population is EVERY shell file under `monitor/`, not the violation set.
# A file scanned and found clean is exactly the file your edit can dirty: that
# is `#803`'s first occurrence, where `monitor/ng` had been in P2's population
# all along and grew a third `shopt -s`/`-u nullglob` pair. Adding the shared
# library and the manifest is not padding — an edit to either changes the
# verdict, and `bash` reads both.
. "$(cd "$_self_dir/.." && pwd)/_guard_population.sh"
gp_population() {
    _aso_shell_files "$REPO_ROOT/monitor"
    printf '%s\n' "$_aso_shf_lib"
    printf '%s\n' "$_self_dir/aso-unresolved-sources.manifest"
}
gp_handle "$@"

# --- fixtures --------------------------------------------------------------
# QUOTED heredocs throughout: the bodies must reach disk verbatim, and an
# unquoted one would also expand `$dir` in the fixture source.
FIXROOT=$(mktemp -d -t aso-fix-XXXXXX)
trap 'rm -rf "$FIXROOT"' EXIT

mkdir -p "$FIXROOT/lib"

cat > "$FIXROOT/lib/masked_lib.sh" <<'EOF'
masked_fn() {
    shopt -s nullglob
    for f in "$1"/*.json; do :; done
    shopt -u nullglob
}
EOF

cat > "$FIXROOT/lib/clean_lib.sh" <<'EOF'
clean_fn() {
    local _r; _r=$(shopt -p nullglob)
    shopt -s nullglob
    for f in "$1"/*.json; do :; done
    eval "$_r"
}
EOF

cat > "$FIXROOT/lib/nonglob_lib.sh" <<'EOF'
nonglob_fn() { printf 'touches no shell option\n'; }
EOF

cat > "$FIXROOT/lib/unsourced_leaker.sh" <<'EOF'
leak_fn() {
    shopt -s nullglob
    shopt -u nullglob
}
EOF

# F-1 (#799 skeptic): the SAME leak, after a separator rather than at line
# start. P2's detector was line-anchored — the fourth site of the gap-4 class
# in this file — so this shape was invisible and P2 erred toward NOT flagging.
# Sourced by a consumer below so it is in the population by the same route the
# real leaks are.
cat > "$FIXROOT/lib/inline_leaker.sh" <<'EOF'
inline_leak_fn() {
    shopt -s nullglob
    x=1; shopt -u nullglob
}
EOF
cat > "$FIXROOT/test-fixture-inline-leak-consumer.sh" <<'EOF'
. "$(dirname "$0")/lib/inline_leaker.sh"
inline_leak_fn /tmp
EOF

# The quiet counterpart, so the assertion above cannot pass by the detector
# simply matching `shopt -u` anywhere: a `shopt -u` that is NOT in command
# position (here inside a longer word) must stay unflagged.
cat > "$FIXROOT/lib/notacommand_lib.sh" <<'EOF'
notacmd_fn() {
    printf 'documented: --shopt -u nullglob is not a command here\n'
}
EOF
cat > "$FIXROOT/test-fixture-notacommand-consumer.sh" <<'EOF'
. "$(dirname "$0")/lib/notacommand_lib.sh"
notacmd_fn
EOF

# Sets nullglob ambiently AND sources the library that scopes it => P1 fires.
cat > "$FIXROOT/test-fixture-masking.sh" <<'EOF'
. "$(dirname "$0")/lib/masked_lib.sh"
shopt -s nullglob
masked_fn /tmp
EOF

# Ambient setter, but the library it sources does not scope nullglob => quiet.
# P1 is about MASKING, so the discriminator is whether the library scopes the
# option AT ALL — the save/restore form still scopes it and is still masked,
# which is why `clean_lib.sh` cannot serve as this cell and gets its own
# consumer below.
cat > "$FIXROOT/test-fixture-ambient-only.sh" <<'EOF'
. "$(dirname "$0")/lib/nonglob_lib.sh"
shopt -s nullglob
EOF

# Consumer with no ambient setter, so `clean_lib.sh` is in the SOURCED
# population P2 scans without being a P1 candidate. Without this the "P2 quiet
# on the save/restore form" assertion would pass because the file was never
# looked at — quiet by population rather than by form, which is not the claim.
cat > "$FIXROOT/test-fixture-clean-consumer.sh" <<'EOF'
. "$(dirname "$0")/lib/clean_lib.sh"
clean_fn /tmp
EOF

# Scoped -s/-u PAIR plus the masked library => quiet (the corpus's real shape).
cat > "$FIXROOT/test-fixture-paired.sh" <<'EOF'
. "$(dirname "$0")/lib/masked_lib.sh"
shopt -s nullglob
masked_fn /tmp
shopt -u nullglob
EOF

# --- fixtures for the four your-org/nexus-code#770 gaps ----------------------------
# Each is reachable ONLY through the gap it names: the pre-#770 scanner is
# quiet on every one of them, so a fixture the old guard would also have caught
# would prove nothing about the widening. Reverting any single fix reddens
# exactly its own assertion (measured, 2026-08-07).

# GAP 1 — the scoping library is at DEPTH 2. `hop_lib.sh` scopes nothing; it
# only sources. A depth-1 scan sees `hop_lib.sh` and stops, so the masking is
# invisible. Save/restore form in the leaf so this fixture stays out of P2 and
# tests exactly one thing.
cat > "$FIXROOT/lib/hop_lib.sh" <<'EOF'
. "$(dirname "${BASH_SOURCE[0]}")/deep_lib.sh"
hop_fn() { deep_fn "$1"; }
EOF
cat > "$FIXROOT/lib/deep_lib.sh" <<'EOF'
deep_fn() {
    local _r; _r=$(shopt -p nullglob)
    shopt -s nullglob
    for f in "$1"/*.json; do :; done
    eval "$_r"
}
EOF
cat > "$FIXROOT/test-fixture-transitive.sh" <<'EOF'
. "$(dirname "$0")/lib/hop_lib.sh"
shopt -s nullglob
hop_fn /tmp
EOF

# GAP 1, the OVER-REPORT direction. Same depth-2 shape, but nothing on the path
# scopes the option — a transitive closure that flagged this would have widened
# P1 into noise rather than into reach.
cat > "$FIXROOT/lib/hop_quiet_lib.sh" <<'EOF'
. "$(dirname "${BASH_SOURCE[0]}")/nonglob_lib.sh"
EOF
cat > "$FIXROOT/test-fixture-transitive-quiet.sh" <<'EOF'
. "$(dirname "$0")/lib/hop_quiet_lib.sh"
shopt -s nullglob
EOF

# GAP 2 — a NESTED `$( … $( ) … )` in the source line, the form three real
# production files use and the fixtures never did. Single-level collapse parses
# the path as `X`, so the library is never seen and P1 is quiet on a live
# masking intersection.
cat > "$FIXROOT/test-fixture-nested-source.sh" <<'EOF'
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/masked_lib.sh"
shopt -s nullglob
masked_fn /tmp
EOF

# GAP 5 (found while checking gap 1's own boundary) — the source path is a
# BARE `$VAR`, assigned a literal a few lines up. No basename survives the
# token filter, so the edge is absent from the graph entirely and P1 is quiet.
cat > "$FIXROOT/lib/var_lib.sh" <<'EOF'
var_fn() {
    local _r; _r=$(shopt -p nullglob)
    shopt -s nullglob
    for f in "$1"/*.json; do :; done
    eval "$_r"
}
EOF
cat > "$FIXROOT/test-fixture-var-source.sh" <<'EOF'
LIB="$(dirname "$0")/lib/var_lib.sh"
. "$LIB"
shopt -s nullglob
var_fn /tmp
EOF

# GAP 5b (#778 skeptic, F2) — the ASSIGNMENT is not line-anchored. This is the
# gap-4 defect re-instantiated inside the gap-5 fix, so its fixture is the
# gap-4 fixture's shape one level in: the setter is ordinary, the SOURCE line is
# ordinary, and only the assignment sits after a separator.
cat > "$FIXROOT/test-fixture-var-source-inline.sh" <<'EOF'
d=$(dirname "$0"); LIB2="$d/lib/var_lib.sh"
. "$LIB2"
shopt -s nullglob
var_fn /tmp
EOF

# GAP 5c (#778 skeptic, F1) — the source TOKEN carries a trailing separator.
# `. "$X"; . "$X"` yields the token `$X;`, which failed the bare-$VAR test for a
# reason having nothing to do with being dynamic. Two real tokens in
# test-locals-env.sh were excluded exactly this way.
cat > "$FIXROOT/test-fixture-var-source-semicolon.sh" <<'EOF'
LIB3="$(dirname "$0")/lib/var_lib.sh"
. "$LIB3"; . "$LIB3"
shopt -s nullglob
var_fn /tmp
EOF

# GAP 5d (#778 skeptic, F1) — an EXTENSIONLESS graph node. `ng` is globbed into
# the index by `_aso_index` and scopes `nullglob` in the real tree, but the
# resolver demanded a `.sh`/`.zsh`/`.bash` suffix, so `NG="…/monitor/ng"` never
# resolved and test-skeptic-channel.sh's ENTIRE graph was absent, not shortened.
#
# THE SHEBANG IS LOAD-BEARING IN THIS FIXTURE, which it was not when the
# population was `-o -name 'ng'`. Under a NAME allowlist, a bare `ng` with no
# first line was indistinguishable from the real one; under the derivation
# (your-org/nexus-code#792) it is correctly not a shell file at all, and the
# fixture went red the moment the enumeration was shared. That is the
# derivation being STRICTER than the list, and it is right: `monitor/ng` is a
# shell file because it says so on line 1, and a fixture that omits that was
# modelling the allowlist rather than the thing.
mkdir -p "$FIXROOT/lib"
cat > "$FIXROOT/lib/ng" <<'EOF'
#!/usr/bin/env bash
ng_fn() {
    local _r; _r=$(shopt -p nullglob)
    shopt -s nullglob
    for f in "$1"/*.json; do :; done
    eval "$_r"
}
EOF
cat > "$FIXROOT/test-fixture-var-source-extensionless.sh" <<'EOF'
NGP="$(dirname "$0")/lib/ng"
. "$NGP"
shopt -s nullglob
ng_fn /tmp
EOF

# GAP 5e — an extensionless node NOBODY HAS ENUMERATED. `ng` above proves the
# graph reaches the one node somebody thought to name; this proves it reaches
# the next one, which is the actual property `#792` is about. A one-element
# allowlist passes the fixture above and fails this one.
cat > "$FIXROOT/lib/brand-new-tool" <<'EOF'
#!/usr/bin/env bash
bnt_fn() {
    local _r; _r=$(shopt -p nullglob)
    shopt -s nullglob
    for f in "$1"/*.json; do :; done
    eval "$_r"
}
EOF
cat > "$FIXROOT/test-fixture-var-source-unnamed-node.sh" <<'EOF'
BNT="$(dirname "$0")/lib/brand-new-tool"
. "$BNT"
shopt -s nullglob
bnt_fn /tmp
EOF

# GAP 3 — a NON-GLOB option. `patsub_replacement` is the one that already cost
# this repo a bash-5.2 debugging round, and it was outside the old fixed list.
cat > "$FIXROOT/lib/patsub_lib.sh" <<'EOF'
patsub_fn() {
    local _r; _r=$(shopt -p patsub_replacement)
    shopt -s patsub_replacement
    printf '%s\n' "${1//x/&}"
    eval "$_r"
}
EOF
cat > "$FIXROOT/test-fixture-nonglob-opt.sh" <<'EOF'
. "$(dirname "$0")/lib/patsub_lib.sh"
shopt -s patsub_replacement
patsub_fn xx
EOF

# GAP 4 — an INLINE CONDITIONAL setter. Line-anchored counting sees zero sets
# here, so the file reads as having no ambient option at all.
cat > "$FIXROOT/test-fixture-inline-setter.sh" <<'EOF'
. "$(dirname "$0")/lib/masked_lib.sh"
[[ -d /tmp ]] && shopt -s nullglob
masked_fn /tmp
EOF

# GAP 4, the two OVER-REPORT directions — these are a regression guard on the
# fix itself, not a demonstration of the gap, and they are the reason the
# comment strip ships with the anchor rather than after it. Both are quiet
# before AND after; a widening that skipped either would red the real tree on
# test-pending-decisions.sh, which carries the balanced inline form at :571 and
# a comment quoting `shopt -s nullglob` at :521.
cat > "$FIXROOT/test-fixture-inline-balanced.sh" <<'EOF'
. "$(dirname "$0")/lib/masked_lib.sh"
if [[ -d /tmp ]]; then shopt -s nullglob; else shopt -u nullglob; fi
masked_fn /tmp
EOF
# The comment here carries a SEPARATOR before the idiom, which is the shape
# this repo's own commentary actually takes — line 66 of this very file reads
# "so `[[ cond ]] && shopt -s nullglob`". The anchor alone does not save it:
# `&&` is a command separator wherever it appears, including inside prose. So
# this fixture is what makes the comment strip load-bearing rather than
# decorative, and it reddens when the strip is removed but the anchor kept
# (measured by mutation, 2026-08-07). A prose fixture WITHOUT a separator would
# pass either way and prove nothing — the first draft of this one did exactly
# that, which is the "fixture the old code also catches" trap one level in.
cat > "$FIXROOT/test-fixture-prose-setter.sh" <<'EOF'
. "$(dirname "$0")/lib/masked_lib.sh"
# the setter count was line-anchored, so `[[ x ]] && shopt -s nullglob` was
# invisible; this line is PROSE about the idiom, not the idiom
masked_fn /tmp
EOF
# A quoted string is not stripped (it is data the script may print), so this
# one pins the ANCHOR's word-position discipline instead. BOUNDARY, stated
# where a reader hits it: a `shopt -s` inside a quoted string that ALSO
# contains a command separator would be counted. That errs toward FLAGGING,
# which is this suite's declared safe direction, and no such string exists in
# the tree today.
cat > "$FIXROOT/test-fixture-quoted-setter.sh" <<'EOF'
. "$(dirname "$0")/lib/masked_lib.sh"
printf '%s\n' "shopt -s nullglob"
masked_fn /tmp
EOF

# The marker must be an exemption, not a decoration. Planted with the rest of
# the fixtures rather than after the scans, so the source-graph index built at
# the first scan is never stale — a cache keyed on the root cannot see a file
# that appeared after it was populated.
cat > "$FIXROOT/lib/marked_lib.sh" <<'EOF'
# ambient-shell-option-scope: allow-unconditional-unset  neutralises a bash 5.2
# default for sourced fixtures, not a caller's option.
marked_fn() { shopt -u patsub_replacement; }
EOF
cat > "$FIXROOT/test-fixture-marked.sh" <<'EOF'
. "$(dirname "$0")/lib/marked_lib.sh"
EOF

# --- P1 --------------------------------------------------------------------
echo "=== P1: ambient harness options must not mask a sourced library ==="

fix_p1=$(aso_scan_masking "$FIXROOT")
assert_contains "P1 fires on a planted masking intersection" \
    "$fix_p1" "test-fixture-masking.sh:nullglob:masked_lib.sh"
assert_not_contains "P1 quiet when the sourced library scopes nothing" \
    "$fix_p1" "test-fixture-ambient-only.sh"
assert_not_contains "P1 quiet on a scoped -s/-u pair" \
    "$fix_p1" "test-fixture-paired.sh"

# --- the four your-org/nexus-code#770 gaps, one assertion apiece -------------------
assert_contains "P1 sees a library scoped at DEPTH 2 (gap 1: transitive sourcing)" \
    "$fix_p1" "test-fixture-transitive.sh:nullglob:deep_lib.sh"
assert_not_contains "P1 quiet when nothing on a depth-2 path scopes the option" \
    "$fix_p1" "test-fixture-transitive-quiet.sh"
assert_contains "P1 sees a NESTED \$( … \$( ) … ) source path (gap 2)" \
    "$fix_p1" "test-fixture-nested-source.sh:nullglob:masked_lib.sh"
assert_contains "P1 sees a source path held in a VARIABLE (gap 5)" \
    "$fix_p1" "test-fixture-var-source.sh:nullglob:var_lib.sh"
# The three residues #778's skeptic found in the gap-5 fix itself.
assert_contains "P1 resolves a variable ASSIGNED after a separator (gap 5b: the gap-4 anchor, again)" \
    "$fix_p1" "test-fixture-var-source-inline.sh:nullglob:var_lib.sh"
assert_contains "P1 resolves a source token carrying a trailing separator (gap 5c)" \
    "$fix_p1" "test-fixture-var-source-semicolon.sh:nullglob:var_lib.sh"
assert_contains "P1 resolves an EXTENSIONLESS graph node such as \`ng\` (gap 5d)" \
    "$fix_p1" "test-fixture-var-source-extensionless.sh:nullglob:ng"
# gap 5e — the same, for a node no enumerator has ever named. This is the
# assertion a one-element allowlist cannot pass (your-org/nexus-code#792).
assert_contains "P1 resolves an extensionless node NOBODY ENUMERATED (gap 5e)" \
    "$fix_p1" "test-fixture-var-source-unnamed-node.sh:nullglob:brand-new-tool"
assert_contains "P1 sees a NON-GLOB option (gap 3: derived option axis)" \
    "$fix_p1" "test-fixture-nonglob-opt.sh:patsub_replacement:patsub_lib.sh"
assert_contains "P1 sees an INLINE CONDITIONAL setter (gap 4: command-position anchor)" \
    "$fix_p1" "test-fixture-inline-setter.sh:nullglob:masked_lib.sh"
assert_not_contains "P1 quiet on a BALANCED inline conditional (the tree's real shape)" \
    "$fix_p1" "test-fixture-inline-balanced.sh"
assert_not_contains "P1 quiet on \`shopt -s\` occurring only in a COMMENT" \
    "$fix_p1" "test-fixture-prose-setter.sh"
assert_not_contains "P1 quiet on \`shopt -s\` occurring only inside a quoted string" \
    "$fix_p1" "test-fixture-quoted-setter.sh"

real_p1=$(aso_scan_masking "$REPO_ROOT/monitor")
if [[ -z "$real_p1" ]]; then
    echo "  PASS: no test file masks an option in a library it sources"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: a test file now masks a shell option in a library it sources." >&2
    echo "        The library's own \`shopt -s\` is dead there, so any assertion" >&2
    echo "        written for it is measuring this harness (your-org/nexus-code#721):" >&2
    printf '%s\n' "$real_p1" | sed 's/^/        /' >&2
    FAIL=$(( FAIL + 1 ))
fi

# --- P2 --------------------------------------------------------------------
echo "=== P2: a SOURCED library must not restore an option unconditionally ==="

# The fixture leaker is sourced by test-fixture-masking.sh, so it is in the
# derived population; unsourced_leaker.sh is referenced by nothing.
fix_p2=$(aso_scan_leaks "$FIXROOT")
assert_contains "P2 fires on an unconditional shopt -u in a SOURCED library" \
    "$fix_p2" "lib/masked_lib.sh"
assert_not_contains "P2 quiet on the save/restore form" "$fix_p2" "clean_lib.sh"
# F-1 (#799 skeptic): P2's own detector was the FOURTH line-anchored site of
# the gap-4 class. Positive first, then the discrimination control — a bare
# "it fires" would also be satisfied by a detector matching `shopt -u`
# anywhere, which is not the property.
assert_contains "P2 sees an unconditional unset AFTER A SEPARATOR (gap 4, 4th site)" \
    "$fix_p2" "lib/inline_leaker.sh"
assert_not_contains "P2 quiet on \`shopt -u\` that is NOT in command position" \
    "$fix_p2" "notacommand_lib.sh"
# Test 6 — the boundary itself, on the axis the mechanism varies on. An
# identical leak in a file NOTHING sources cannot reach a caller, and must not
# be reported as one.
assert_not_contains "P2 quiet on an identical leak nothing sources" \
    "$fix_p2" "unsourced_leaker.sh"

real_p2=$(aso_scan_leaks "$REPO_ROOT/monitor")
if [[ -z "$real_p2" ]]; then
    echo "  PASS: no sourced library restores a shell option unconditionally"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: a sourced library hands its caller a shell option OFF however" >&2
    echo "        the caller had it. Use main.sh's save/restore form, or carry" >&2
    echo "        the '$MARKER' marker WITH a reason:" >&2
    printf '%s\n' "$real_p2" | sed 's/^/        /' >&2
    FAIL=$(( FAIL + 1 ))
fi

# --- P3a: the TOKENISER's bound, pinned as data -----------------------------
#
# your-org/nexus-code#793(a), the half that matters more than the regex.
#
# The residue is a residue OF TOKENS. A source statement the tokeniser never
# tokenises produces no token, so **it cannot appear in the manifest by
# construction** — the manifest is structurally blind to exactly what it misses.
# Its 19 entries read as "these 19 are all that is unresolved" when the true
# statement is "these 19 are all that is unresolved AMONG STATEMENTS THE
# TOKENISER SAW." Nobody had written that down, and while the tokeniser was
# line-anchored it was hiding 51 real source statements behind that gap.
#
# Fixing the anchor does not retire the bound; it moves it. So the bound is
# pinned the same way the residue is: as DATA. Every shape the tokeniser claims
# to see, and every shape it claims not to, is planted here and its output
# asserted exactly. A regression in the reader reds a test instead of silently
# shrinking a manifest that then agrees with itself.
echo "=== P3a: what the TOKENISER can and cannot see, as data not prose ==="

# The shapes are written with `@DOT@`/`@SRC@` placeholders and substituted on
# the way to disk, so THIS file's own source text contains no source statement
# it did not mean to make. Without that the fixture is self-referential: the
# suite is itself in the scanned population, its heredoc's `. "$BAREVAR"` is a
# perfectly real source token, and it landed in the residue manifest — a
# manifest describing test scaffolding rather than the tree. Same hazard the
# MARKER at the top of this file exists for, one mechanism along.
_aso_shapes_dir=$(mktemp -d -t aso-shapes-XXXXXX)
sed -e 's/@DOT@/./g' -e 's/@SRC@/source/g' > "$_aso_shapes_dir/shapes.sh" <<'SHAPES'
@DOT@ line_anchored.sh
    @DOT@ indented.sh
x=1; @DOT@ after_semicolon.sh
[[ -f f ]] && @DOT@ after_and.sh
false || @DOT@ after_or.sh
if x; then @DOT@ after_then.sh; fi
for i in 1; do @DOT@ after_do.sh; done
if x; then :; else @DOT@ after_else.sh; fi
{ @DOT@ after_brace.sh; }
@SRC@ spelled_out.sh
@DOT@ "$(dirname "$0")/collapsed.sh"
@DOT@ "${SOMEVAR:-defaulted.sh}"
@DOT@ "$BAREVAR"
@DOT@ a.sh; @DOT@ b.sh; @DOT@ c.sh
# a comment naming @DOT@ commented.sh must not count
echo "a string ending a sentence). Or not"
jqfilter='select(. != "")'
SHAPES

# SEEN — one assertion per shape, all POSITIVE, so a tokeniser broken into
# emitting nothing fails every one of them rather than passing by silence.
_aso_shape_toks=$(_aso_source_tokens "$_aso_shapes_dir/shapes.sh")
for _s in line_anchored.sh indented.sh after_semicolon.sh after_and.sh \
          after_or.sh after_then.sh after_do.sh after_else.sh after_brace.sh \
          spelled_out.sh collapsed.sh defaulted.sh; do
    assert_contains "tokeniser SEES: $_s" "$_aso_shape_toks" "$_s"
done
assert_contains "tokeniser SEES: a bare \$VAR target" "$_aso_shape_toks" '$BAREVAR'

# THREE statements on one line must yield THREE tokens. The old reader used
# `sed -nE …p`, which prints at most one substitution per line, so a line
# carrying several sources contributed one token — a quieter half of the same
# defect, and the reason the filed count of 18 undercounted.
assert_eq "tokeniser sees ALL THREE sources on one line (not just the first)" \
    "$(grep -cE '^[abc]\.sh$' <<<"$_aso_shape_toks")" 3

# NOT SEEN — the declared bound. Each is paired above with a shape that IS
# seen, so these absences cannot be satisfied by an empty tokeniser.
assert_not_contains "tokeniser does NOT see: a source named only in a comment" \
    "$_aso_shape_toks" "commented.sh"
assert_not_contains "tokeniser does NOT see: an English full stop after ')'" \
    "$_aso_shape_toks" "Or"
assert_not_contains "tokeniser does NOT see: a jq identity filter '(. != …)'" \
    "$_aso_shape_toks" "!="

# The unsafe-direction gap, RE-MEASURED rather than asserted. The header names
# it and claims zero live occurrences; this is what re-checks that claim on
# every CI run instead of trusting the paragraph — which is the discipline the
# whole `#793` thread is about.
#
# The label deliberately does not spell the idiom out. `_aso_code` strips
# comments but keeps STRING data, so an assertion whose own label contained
# `<separator><dot><space>` matched itself and reported one live instance in
# the file doing the measuring. Third self-reference in this section, and the
# reason the shape fixture above is placeholder-substituted.
_aso_nospace=$(_aso_shell_files "$REPO_ROOT/monitor" \
    | while IFS= read -r f; do
          _aso_code "$f" | grep -nE '[;&|]\.[[:space:]]+[^[:space:]]' | sed "s|^|${f#"$REPO_ROOT"/}:|"
      done)
assert_empty "the declared no-space separator gap has zero live instances" \
    "$_aso_nospace"

rm -rf "$_aso_shapes_dir"

# --- P3: the RESIDUE is pinned, not described -------------------------------
echo "=== P3: the set of source tokens the graph cannot resolve is a MANIFEST ==="

_aso_manifest="$_self_dir/aso-unresolved-sources.manifest"
if [[ -r "$_aso_manifest" ]]; then
    _aso_live=$(_aso_unresolved_sources "$REPO_ROOT/monitor")
    _aso_recorded=$(cat "$_aso_manifest")

    # NON-VACUITY (your-org/nexus-code#793(b)). Evaluated through
    # `_aso_p3_verdicts`, and then — the part that makes it evidence rather than
    # a claim — evaluated AGAIN against a deliberately broken resolver, with the
    # assertion that it goes red.
    _aso_tok_total=$(_aso_source_token_total "$REPO_ROOT/monitor")
    _aso_v=$(_aso_p3_verdicts "$_aso_live" "$_aso_tok_total")
    if ! grep -q '=BROKEN' <<<"$_aso_v"; then
        echo "  PASS: P3's non-vacuity guards all hold ($_aso_tok_total tokens, $(printf '%s\n' "$_aso_live" | grep -c .) unresolved)"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: a P3 non-vacuity guard is broken:" >&2
        grep '=BROKEN' <<<"$_aso_v" | sed 's/^/          /' >&2
        echo "        population      — the TOKENISER found too few source tokens." >&2
        echo "        residue-floor   — the RESOLVER resolved (almost) everything." >&2
        echo "        positive-…      — a token that can NEVER resolve is missing." >&2
        echo "        control-…       — a token that CAN resolve is present." >&2
        FAIL=$(( FAIL + 1 ))
    fi

    # THE BREAK, RUN. `_ASO_BREAK_RESOLVER=1` is the classifier-broken-into-
    # agreement failure the manifest invites: the resolver resolves everything,
    # the residue empties, and a manifest regenerated from it agrees perfectly.
    # Before this, that scenario passed 25 of 25 with a 0-token manifest. Now it
    # is executed on every run and the guards must FAIL on it — asserted on the
    # two POSITIVE guards specifically, because those are the ones an absence
    # cannot satisfy and therefore the ones that carry the property.
    #
    # Scoped to `watcher/` rather than all of `monitor/` purely for cost: it is
    # a second full residue computation, and the subtree carries the great
    # majority of the dynamic tokens. The floor below is checked against what
    # that subtree really yields, so the break cannot pass by looking at little.
    _aso_break_root="$REPO_ROOT/monitor/watcher"
    _aso_break_live=$(_ASO_BREAK_RESOLVER=1 _aso_unresolved_sources "$_aso_break_root")
    # The UNBROKEN control is SLICED out of `$_aso_live`, not recomputed.
    # `_aso_unresolved_sources` decides each token from its own file alone, so
    # restricting the file set restricts the rows exactly — the `watcher/` rows
    # of the `monitor` residue ARE the `monitor/watcher` residue, modulo the
    # stripped prefix. Recomputing cost a third full pass over the subtree for
    # an answer already in hand. The break run itself cannot be sliced, because
    # its whole point is to recompute with a different resolver.
    _aso_break_base=$(grep '^watcher/' <<<"$_aso_live" || true)
    _aso_break_total=$(_aso_source_token_total "$_aso_break_root")

    # The break must actually break something — otherwise "the guards went red"
    # would be unfalsifiable. Pin that the UNBROKEN subtree residue is
    # substantial and the broken one is empty.
    assert_eq "the break demonstrably empties the residue (control: unbroken is not empty)" \
        "$( { [[ -z "$_aso_break_live" ]] && \
              (( $(printf '%s\n' "$_aso_break_base" | grep -c .) >= 10 )); } \
            && echo yes || echo no )" yes

    _aso_bv=$(_aso_p3_verdicts "$_aso_break_live" "$_aso_break_total")
    assert_contains "…and the residue floor CATCHES it (the guard bites)" \
        "$_aso_bv" "residue-floor=BROKEN"
    assert_contains "…and so does the positive unresolvable-token guard" \
        "$_aso_bv" "positive-unresolvable=BROKEN"
    # The counterpart, and the point of the whole finding: the guards that
    # SHIPPED are satisfied by the break. Asserted rather than described, so
    # nobody re-derives them as sufficient. The population floor is unmoved
    # because it measures the tokeniser, one stage upstream; the `$NG` control
    # is satisfied because absent-because-empty looks like absent-because-
    # resolved.
    assert_contains "the shipped population floor is UNMOVED by the break (it measures the tokeniser)" \
        "$_aso_bv" "population=ok"
    assert_contains "the shipped \$NG control is SATISFIED by the break (an absence cannot be a control)" \
        "$_aso_bv" "control-resolvable=ok"

    # The manifest must be reproducible on a host that is not this one. Mirrors
    # test-early-exit-reader-manifest.sh:241, and pinned for the same reason:
    # so the `LC_ALL=C` in the emitter cannot be dropped silently. It was
    # MISSING on this suite's first push and reddened all six CI unit cells.
    assert_eq "P3: the residue is locale-independent (C == en_US.utf8)" \
        "$_aso_live" \
        "$(LC_ALL=en_US.utf8 _aso_unresolved_sources "$REPO_ROOT/monitor")"

    if [[ "$_aso_live" == "$_aso_recorded" ]]; then
        echo "  PASS: the unresolved-source set matches the recorded manifest ($(printf '%s\n' "$_aso_recorded" | grep -c .) tokens)"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: the set of source tokens the graph CANNOT resolve has changed." >&2
        echo "        This file has twice carried a BOUNDARY sentence that was honest and" >&2
        echo "        false (your-org/nexus-code#770, #778 F1); the manifest exists so the third" >&2
        echo "        time is a red test rather than a paragraph. Decide which happened:" >&2
        echo "          - FEWER tokens: you widened the resolver. Regenerate and say what" >&2
        echo "            shape you closed, in the BOUNDARY note." >&2
        echo "          + MORE tokens: a new shape resolves to no edge. Is it GENUINELY" >&2
        echo "            shell-dependent (a loop variable, a positional parameter, inherited" >&2
        echo "            env), or is it statically resolvable and hiding behind a" >&2
        echo "            principled-sounding sentence? That was F1, twice." >&2
        echo "        Regenerate with:" >&2
        echo "          bash monitor/watcher/test-ambient-shell-option-scope.sh --emit-unresolved \\" >&2
        echo "              > monitor/watcher/aso-unresolved-sources.manifest" >&2
        diff <(printf '%s\n' "$_aso_recorded") <(printf '%s\n' "$_aso_live") \
            | sed 's/^/        /' >&2 || true
        FAIL=$(( FAIL + 1 ))
    fi
else
    echo "  FAIL: missing $_aso_manifest — the residue would go unchecked" >&2
    FAIL=$(( FAIL + 1 ))
fi

# --- the marker must be an exemption, not a decoration ----------------------
# (the fixture itself is planted with the others, above)
assert_not_contains "the marker exempts a sourced library" \
    "$fix_p2" "marked_lib.sh"

th_summary_and_exit
