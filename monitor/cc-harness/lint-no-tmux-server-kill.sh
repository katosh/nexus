#!/usr/bin/env bash
# monitor/cc-harness/lint-no-tmux-server-kill.sh — tmux-socket safety lint.
#
# Sibling of lint-no-mass-kill.sh. That one draws its boundary on the PROCESS
# axis (`pkill -f` matches the shared claude binary across the sandbox's one
# PID namespace). This one draws it on the TMUX-SOCKET axis, where the blast
# radius is strictly worse.
#
# WHY. `bwrap` is PID 1 and runs `tmux new-session ./watcher` under
# `--die-with-parent --unshare-pid`. Ending the tmux server ends the session,
# so the bwrap child exits and the ENTIRE SANDBOX is torn down — tmux server,
# watcher, every worker, every registered service. On 2026-07-30 that happened
# five times in 33 minutes (your-org/nexus-code#644).
#
# THE TRAP THAT CAUSED IT. tmux resolves its socket in this precedence:
#
#     -L / -S   >   $TMUX   >   TMUX_TMPDIR   >   compiled default
#
# `$TMUX` sits ABOVE `TMUX_TMPDIR`. Every nexus agent runs INSIDE a tmux pane,
# so `$TMUX` is always set. A test that isolates itself with `TMUX_TMPDIR`
# alone is therefore NOT isolated. The offending line read:
#
#     TMUX_TMPDIR="$TSOCK" "$REAL_TMUX" kill-server 2>/dev/null || true
#
# which LOOKS scoped and is not.
#
# ENUMERATE FROM THE HAZARD, NOT THE VERB. "What can terminate the server?" —
# not just `kill-server`. Killing the last window of the last session exits the
# server too (verified: `tmux -L p new-session -d -s a`; `kill-window -t a:0`
# leaves "no server running"). Same for the last session, and the last pane.
# So the ruleset keys on the SCOPING IDIOM rather than on a verb list: rule2
# fires on ANY tmux invocation scoped only by TMUX_TMPDIR — `new-session` and
# `kill-window` included — because a verb allowlist will always lag the next
# way somebody finds to end a server.
#
# RULES (fail-CLOSED — anything not provably safe is a violation):
#
#   1. `kill-server` must carry `-L <name>`/`-S <path>` on the SAME command.
#      This is a BRIGHT LINE and is deliberately stricter than rule2:
#      `env -u TMUX TMUX_TMPDIR=X tmux kill-server` is genuinely isolated and
#      is STILL a violation. kill-server is the one unconditionally fatal verb,
#      and that form's correctness rests on two things being right at once (the
#      unset AND the tmpdir) where `-L` rests on one. For this verb the lint
#      demands the form a reviewer can check without thinking. The remedy is
#      one flag.
#   2. A tmux invocation scoped only by `TMUX_TMPDIR` — no `-L`/`-S`, no
#      `env -u TMUX` on that same command — is unisolated. LOCAL check only.
#   3. `kill-session`/`kill-window`/`kill-pane` must name a target (`-t`);
#      untargeted acts on the CURRENT one, which can be the last.
#   4. `-L default` / `-S …/default` is syntactically a pin and semantically
#      the operator's own server.
#
# WHY RULE 2 IS LOCAL. It used to accept a file-scoped `unset TMUX` as proof of
# neutralisation. That was wrong twice: it fired on ZERO lines of the file that
# caused the incident (which carries `unset TMUX` at line 277, inside a
# heredoc), and a single `unset TMUX` in a COMMENT silenced the rule for an
# entire file — an uncounted, self-service escape hatch, the exact erosion the
# counted-pragma discipline below exists to prevent. Neutralisation must now be
# on the command itself.
#
# DATA IS NOT CODE. The scanner (`_tmux_kill_scan.awk`) splits each line into
# command fragments and only treats a verb as an invocation when its fragment's
# command word is a tmux reference. `assert_not_contains … "kill-server"` and
# `printf ' tmux kill-window -t %s'` are corpus, not calls. Making authors
# annotate non-calls is how a counted hatch decays into noise.
#
# ESCAPE HATCH. A call routed through a socket-pinned wrapper cannot be proven
# safe from one line; it may carry an inline pragma:
#
#     ... kill-server ...   # tmux-scoped: <why this is socket-pinned>
#
# Pragmas are COUNTED and the count is pinned by `--selftest`, so an exemption
# cannot be added silently. A pragma never exempts rule2 or rule4 — those
# describe a scoping idiom that is a no-op regardless of author intent.
#
# COVERAGE BOUNDARY (one sentence, on the axis the mechanism varies on):
#   A SECOND, HARDER LIMIT — VERB RESOLUTION (your-org/nexus-code#892, F6).
#   `command-alias` is a SETTABLE SERVER OPTION: `set -s command-alias[99]
#   'nuke=kill-server'` makes `tmux nuke` a server-killer, and the mapping is
#   runtime state that exists only in a running server. A static lint cannot
#   resolve it — not "has not yet", but CANNOT, because the fact is not in the
#   text. This lint therefore covers the BUILT-IN vocabulary (including
#   abbreviations and the `killp`/`killw` short forms) and is structurally blind
#   to user aliases. The runtime shim `monitor/tmuxwrap/tmux` closes that case
#   by asking the server; the split is deliberate and is why both exist.
#
#   This lint decides a tmux call by the SOCKET RESOLUTION PROVABLE AT ITS CALL
#   SITE — `-L`/`-S` (not naming `default`) passes, `TMUX_TMPDIR`-only fails,
#   and a wrapper-routed call needs a counted pragma — so it CANNOT decide
#   whether a *correctly targeted* `kill-window`/`kill-session` happens to be
#   removing the last window or session of an intentionally-ambient server,
#   which is a runtime property and is deliberately out of scope.
#
# WHICH FILES (the second boundary, and the one that was silently wrong).
#   Until your-org/nexus-code#792 this lint enumerated `*.sh -o *.zsh -o *.bash`
#   and was therefore BLIND to all ELEVEN shell files under `monitor/` that
#   carry no such extension — including `monitor/ng`, the largest shell file in
#   the repo and the most-invoked entry point, and the four zsh startup files
#   under `shellenv/`. A guard that cannot read the file agents edit most is not
#   guarding it, and this is the guard whose failure is UNRECOVERABLE.
#
#   The population is now DERIVED, in `monitor/shell-files.sh`, shared with
#   `lint-no-mass-kill.sh` and the watcher's scope guard so that four
#   enumerations which gave four different answers are one. Note what was NOT
#   done: the in-tree pattern available to copy was
#   `\( -name '*.sh' -o -name 'ng' \)`, a ONE-ELEMENT ALLOWLIST that would have
#   closed `ng` and left the other ten. Reusing it would have been writing the
#   same defect with a longer list. A twelfth extensionless executable added
#   tomorrow is covered with nobody remembering — `shf_class`'s shebang arm is
#   what decides — and section 7 of `--selftest` plants exactly that file under
#   a name nothing in this repo has heard of and proves the lint reads it.
#
# Usage:
#   lint-no-tmux-server-kill.sh [target-dir]   default: the repo's monitor/
#   lint-no-tmux-server-kill.sh --manifest [target-dir]
#   lint-no-tmux-server-kill.sh --selftest     negative control (see above)
#
# Exit: 0 = clean, 1 = violation (offending lines on stderr), 2 = usage error.
set -uo pipefail

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
self_base=$(basename "${BASH_SOURCE[0]}")
repo_root=$(cd "$self_dir/../.." && pwd)
AWK_SCAN="$self_dir/_tmux_kill_scan.awk"
FIXTURE="$self_dir/fixtures/incident-644-test-spawn-liveness.sh.txt"
PRAGMA='# tmux-scoped:'

[[ -r "$AWK_SCAN" ]] || { echo "missing scanner: $AWK_SCAN" >&2; exit 2; }

# The DERIVED shell-file population (your-org/nexus-code#792) — see WHICH FILES
# above. Sourced rather than reimplemented: four independent enumerations is how
# this repo came to hold four different answers to one question (`#775`).
SHELL_FILES_LIB="$repo_root/monitor/shell-files.sh"
[[ -r "$SHELL_FILES_LIB" ]] || {
    echo "missing shell-file enumerator: $SHELL_FILES_LIB" >&2; exit 2; }
. "$SHELL_FILES_LIB"

# This lint parses SHELL syntax (`_tmux_kill_scan.awk` decides a command word),
# so its population is the `shell` class, not the wider `script` one.
#
# Self-exclusion stays where it was — this file names every banned idiom in its
# own comments and fixtures by construction — but it now happens INSIDE the
# enumerator's output rather than as a `find` predicate, so there is exactly one
# place where the file list is built.
files0() {   # <root> -> NUL-separated shell files, minus this lint itself
    local f
    shf_find0 "$1" shell | while IFS= read -r -d '' f; do
        [[ "${f##*/}" == "$self_base" ]] && continue
        printf '%s\0' "$f"
    done
}

scan_file() { awk -f "$AWK_SCAN" "$1" 2>/dev/null | sed "s|^|$1:|"; }

scan() {
    local target="$1" f
    files0 "$target" | while IFS= read -r -d '' f; do scan_file "$f"; done
}

count_pragmas() {
    files0 "$1" \
      | xargs -0 grep -hF "$PRAGMA" 2>/dev/null \
      | grep -cE 'kill-server|kill-session|kill-window|kill-pane' || true
}

explain() {
    cat >&2 <<'EXPLAIN'
LINT FAIL — tmux call is not provably socket-scoped at its call site.

  Ending the tmux server ends the session bwrap holds open, so the ENTIRE
  SANDBOX is torn down (your-org/nexus-code#644 — five tear-downs in 33
  minutes). Killing the last window of the last session ends it too.
  Precedence:  -L / -S  >  $TMUX  >  TMUX_TMPDIR  >  default

  rule1-killserver-unscoped     kill-server with no -L/-S.
  rule2-tmux-tmpdir-insufficient  scoped only by TMUX_TMPDIR. $TMUX (always
                                set — every agent runs in a pane) beats it, so
                                the call hits the REAL server. Add -L/-S, or
                                `env -u TMUX` ON THE SAME COMMAND.
  rule3-untargeted-kill         kill-session/window/pane with no -t; acts on
                                the CURRENT one, which can be the last.
  rule4-pins-default-socket     -L default / -S …/default is the operator's
                                own server.

  Wrapper-routed and genuinely safe? Annotate inline with a reason:
      ... kill-server ...   # tmux-scoped: <why this wrapper pins a socket>
  Pragmas are counted and pinned by --selftest. They never exempt rule2/rule4.
EXPLAIN
}

# ---------------------------------------------------------------------------
# --selftest — NEGATIVE CONTROL.
#
# The headline case runs against a VERBATIM EXCERPT OF THE REAL CULPRIT
# (fixtures/incident-644-*.txt). The previous version of this lint asserted
# only against synthetic one-liners and shipped claiming rule2 was "the check
# that would have caught this incident" when, against the actual file, rule2
# fired on ZERO lines. A rule that fires on nothing in the file it was written
# for is a guard asserting a proxy.
# ---------------------------------------------------------------------------
selftest() {
    local tmp out fails=0 passes=0
    tmp=$(mktemp -d) || { echo "selftest: mktemp failed" >&2; return 1; }
    trap 'rm -rf "$tmp"' RETURN

    _ck() {  # _ck <label> <condition-result 0/1> [detail]
        if (( $2 == 0 )); then printf '  PASS: %s\n' "$1"; passes=$((passes+1))
        else printf '  FAIL: %s%s\n' "$1" "${3:+ — $3}" >&2; fails=$((fails+1)); fi
    }

    _expect() {   # _expect <label> <want-rule|CLEAN> <file-content>
        local label="$1" want="$2" body="$3" d
        d=$(mktemp -d "$tmp/case.XXXXXX"); printf '%s\n' "$body" > "$d/planted.sh"
        out=$(scan "$d" 2>&1)
        if [[ "$want" == CLEAN ]]; then
            _ck "$label" $([[ -z "$out" ]] && echo 0 || echo 1) "expected clean, got: $out"
        else
            _ck "$label → $want" $(grep -qF ":$want:" <<<"$out" && echo 0 || echo 1) \
                "got: ${out:-<clean>}"
        fi
    }

    # === 1. THE REAL CULPRIT ===============================================
    echo "=== negative control vs the REAL culprit (verbatim excerpt) ==="
    if [[ ! -r "$FIXTURE" ]]; then
        _ck "incident fixture present" 1 "missing $FIXTURE"
    else
        out=$(scan_file "$FIXTURE")

        _ck "the EXIT trap that did the killing is caught" \
            $(grep -qE ':13:rule(1|2)-' <<<"$out" && echo 0 || echo 1) "got: $out"

        # Both rules must fire on it: rule1 (no -L) AND rule2 (TMUX_TMPDIR-only).
        _ck "…by rule1 AND rule2, not just one" \
            $( { grep -qF ':13:rule1-killserver-unscoped:' <<<"$out" \
              && grep -qF ':13:rule2-tmux-tmpdir-insufficient:' <<<"$out"; } && echo 0 || echo 1) \
            "got: $(grep ':13:' <<<"$out")"

        # THE REGRESSION THAT SHIPPED: rule2 must not be silenced by the
        # `unset TMUX` living in the shim heredoc a few lines below.
        _ck "rule2 is NOT silenced by a distant 'unset TMUX' (the shipped bug)" \
            $(grep -qF ':13:rule2-tmux-tmpdir-insufficient:' <<<"$out" && echo 0 || echo 1)

        # THE CLASS: fixing only what rule1 demands must NOT make it clean.
        local fixed; fixed=$(mktemp -d "$tmp/fixed.XXXXXX")
        sed 's|\("\$REAL_TMUX"\) kill-server|\1 -L "$SOCKN" kill-server|' \
            "$FIXTURE" > "$fixed/f.sh"
        local after; after=$(scan_file "$fixed/f.sh")
        _ck "applying ONLY the -L rule1 demands leaves the file DIRTY" \
            $([[ -n "$after" ]] && echo 0 || echo 1) \
            "file went clean while other lines still hit the default socket"

        # Specifically: the session-CREATING line and the kill-windows.
        _ck "the line that CREATES a session on the operator's server is caught" \
            $(grep -qE ':30:rule2-' <<<"$out" && echo 0 || echo 1) "got: $(grep ':30:' <<<"$out")"
        _ck "unisolated kill-window lines are caught (server-ending, not kill-server)" \
            $( { grep -qE ':35:rule2-' <<<"$out" && grep -qE ':43:rule2-' <<<"$out"; } && echo 0 || echo 1) \
            "got: $(grep -E ':(35|43):' <<<"$out")"

        # And the shim that got it RIGHT must not be flagged.
        _ck "the correctly-written shim body is NOT flagged" \
            $(grep -qE ':(2[0-5]):' <<<"$out" && echo 1 || echo 0) \
            "false positive on the correct shim: $(grep -E ':(2[0-5]):' <<<"$out")"

        local n; n=$(grep -c . <<<"$out")
        printf '  (fixture yields %s violations across %s lines)\n' \
            "$n" "$(wc -l < "$FIXTURE")"
    fi

    # === 2. the erosion mode ===============================================
    echo "=== the escape hatch that was self-service ==="
    _expect 'a COMMENTED "unset TMUX" no longer silences rule2' \
        rule2-tmux-tmpdir-insufficient \
'# unset TMUX -- just a comment
TMUX_TMPDIR="$T" tmux new-session -d -s x'
    _expect 'an `unset TMUX` elsewhere in the file no longer silences rule2' \
        rule2-tmux-tmpdir-insufficient \
'f() { unset TMUX; }
TMUX_TMPDIR="$T" tmux kill-window -t a:0'
    _expect 'a pragma does NOT exempt rule2' rule2-tmux-tmpdir-insufficient \
'TMUX_TMPDIR="$T" tmux new-session -d -s x   # tmux-scoped: I promise it is fine'

    # === 3. the hazard beyond kill-server ==================================
    echo "=== server-ending operations that are not kill-server ==="
    _expect 'untargeted kill-window' rule3-untargeted-kill 'tmux -L iso kill-window'
    _expect 'untargeted kill-session' rule3-untargeted-kill 'tmux -L iso kill-session'
    _expect 'untargeted kill-pane' rule3-untargeted-kill 'tmux -L iso kill-pane'
    _expect 'a pin naming the DEFAULT socket' rule4-pins-default-socket \
'tmux -L default kill-server'

    # === 3b. tmux's REAL grammar (your-org/nexus-code#892, skeptic F2/F3) ==
    #
    # Both of these scanned CLEAN until now, and both were EXECUTED against a
    # real server, which died. A verb allowlist does not model tmux: it accepts
    # any unambiguous command PREFIX, and it takes several commands in one
    # invocation separated by `\;`.
    echo "=== abbreviations and command sequences ==="
    _expect 'an ABBREVIATED kill-server (kill-ser)' rule1-killserver-unscoped \
'tmux kill-ser'
    _expect 'a one-letter abbreviation (k)' rule1-killserver-unscoped 'tmux k'
    _expect 'an abbreviated kill-window is still untargeted' rule3-untargeted-kill \
'tmux -L iso kill-wind'
    _expect 'kill-server in the SECOND position of a \; sequence' \
        rule1-killserver-unscoped 'tmux list-windows \; kill-server'
    _expect 'an untargeted kill later in a pinned sequence' rule3-untargeted-kill \
'tmux -L iso list-windows \; kill-window'
    _expect 'an earlier -t does NOT satisfy a later untargeted kill' \
        rule3-untargeted-kill 'tmux -L iso kill-window -t a:1 \; kill-pane'
    # CONTROLS — the over-refusal direction. A prefix of a NON-kill command, and
    # a fully-scoped sequence, must both stay clean.
    _expect 'the killp short form' rule3-untargeted-kill 'tmux -L iso killp'
    _expect 'the killw short form' rule3-untargeted-kill 'tmux -L iso killw'
    _expect 'a targeted killw is fine' CLEAN 'tmux -L iso killw -t a:1'
    _expect 'tmux -- kill-server (option terminator)' rule1-killserver-unscoped \
'tmux -- kill-server'
    _expect 'a non-kill abbreviation is not a kill' CLEAN 'tmux -L iso list-w'
    _expect 'a fully targeted, pinned sequence' CLEAN \
'tmux -L iso kill-window -t a:1 \; kill-pane -t a:2'
    _expect 'a kill-free sequence' CLEAN 'tmux -L iso list-windows \; list-panes'

    # === 4. plain unscoped forms ===========================================
    echo "=== unscoped forms ==="
    _expect 'bare kill-server' rule1-killserver-unscoped 'tmux kill-server'
    _expect 'kill-server behind a PATH shim' rule1-killserver-unscoped \
'PATH="$bogus:$PATH" tmux kill-server 2>/dev/null || true'
    # The prefix VALUE may contain whitespace, and the scanner splits on
    # whitespace before deciding the command word. `IFS=" "` therefore arrived
    # as two tokens: the prefix arm ate `IFS="`, the loop returned `"` as the
    # command word, `is_tmux_word` said no, and an UNSCOPED kill-server was
    # reported CLEAN. Same assignment-prefix blind spot as
    # your-org/nexus-code#775, but fail-OPEN — #775 cries wolf on a correct doc
    # snippet, this waved a real server-killer through. `PATH="$bogus:$PATH"`
    # above did not catch it because that value has no space in it.
    _expect 'kill-server behind a QUOTED prefix value containing a space' \
        rule1-killserver-unscoped 'IFS=" " tmux kill-server'
    _expect 'kill-window behind TWO prefixes, one quoted' rule3-untargeted-kill \
'LC_ALL=C IFS=" " tmux kill-window'
    _expect 'a quoted prefix does not break the SCOPED positive control' CLEAN \
'IFS=" " tmux -L iso kill-window -t "live:$idx"'
    _expect 'kill-server deferred inside a trap body' rule1-killserver-unscoped \
"trap 'tmux kill-server 2>/dev/null || true' EXIT"

    # === 5. positive controls ==============================================
    echo "=== provably-scoped forms must PASS ==="
    _expect 'explicit -L' CLEAN 'tmux -L "$sock" kill-server 2>/dev/null'
    _expect 'explicit -S' CLEAN 'tmux -S "$TMX_SOCK" kill-server >/dev/null 2>&1 || true'
    # `env -u TMUX` satisfies rule2 — but NOT rule1's bright line. Asserted
    # explicitly so the stricter-than-necessary choice is visible and
    # deliberate rather than an unnoticed false positive.
    _expect 'env -u TMUX satisfies rule2 on a non-destructive call' CLEAN \
'env -u TMUX TMUX_TMPDIR="$T" tmux new-session -d -s x'
    _expect 'but kill-server still demands -L/-S (bright line)' \
        rule1-killserver-unscoped \
'env -u TMUX TMUX_TMPDIR="$T" tmux kill-server'
    _expect 'targeted kill-window on a pinned socket' CLEAN \
'tmux -L iso kill-window -t "live:$idx"'
    _expect 'trap with an -L pin' CLEAN \
"trap 'tmux -L \"\$SOCK\" kill-server 2>/dev/null || true' EXIT"
    _expect 'pragma-annotated wrapper call' CLEAN \
'cch_tmux kill-server 2>/dev/null || true   # tmux-scoped: cch_tmux pins -L "$CCH_SOCKET"'

    # === 6. data is not code ===============================================
    echo "=== corpus must not be read as calls ==="
    _expect 'assertion string' CLEAN \
'assert_not_contains "respawn NEVER kills the server" "$tmux_log" "kill-server"'
    _expect 'assertion naming a full command' CLEAN \
'assert_contains "id record: kill targets the window ID" "$sec_id" "tmux kill-window -t @42"'
    _expect 'printf of remediation advice' CLEAN \
"printf '  tmux kill-window -t %s && tmux new-window -dn %s' \"\$w\" \"\$n\""
    _expect 'echo of a section header' CLEAN 'echo "=== kill-window ==="'
    _expect 'full-line comment' CLEAN '    # never run tmux kill-server here'
    _expect 'tmux format string survives comment-stripping' CLEAN \
'tmux -L iso list-windows -t live -F "#{window_name}"'

    # === 6b. a JSON payload is data, even when it names a real command ======
    #
    # THE REGRESSION THIS PINS. Word-splitting runs before quote-stripping, so
    # `"tmux kill-server"` reached `sub_verb` as `"tmux` + `kill-server"` and the
    # decoration-stripper turned the second into a bare verb — promoting a
    # string literal into a call site by deleting the very quote that proved it
    # was a literal. It fired on THIRTEEN hook fixtures in
    # `monitor/watcher/test-bash-footgun-guard.sh`, and since `gate.sh` runs
    # this lint as a pre-flight, `test-cc-gate.sh` then lost five assertions
    # that never executed (2 pass / 5 fail).
    #
    # These are asserted CLEAN rather than pragma-annotated on purpose. A
    # pragma would record a false positive as a safety exemption and inflate
    # the counted-hatch manifest by thirteen — the erosion the count exists to
    # detect. The shapes below are verbatim from that corpus, including the
    # ones where a `&&`/`;` INSIDE the payload splits the fragment so the
    # command word is a bare `tmux` and only the verb carries the stray quote.
    echo "=== a command named inside a JSON payload is not a call ==="
    _expect 'a hook fixture naming kill-server' CLEAN \
'run '\''{"tool_name":"Bash","tool_input":{"command":"tmux kill-server"}}'\'''
    _expect 'a hook fixture naming an untargeted kill-window' CLEAN \
'run '\''{"tool_name":"Bash","tool_input":{"command":"tmux kill-window"}}'\'''
    _expect 'a payload whose && splits the fragment' CLEAN \
'run '\''{"tool_name":"Bash","tool_input":{"command":"cd /tmp && tmux kill-server"}}'\'''
    # Verbatim but for the leading verb: the corpus line reads `tmux new-window
    # ; tmux kill-window`, and `new-window` inside this string would enrol the
    # line in `test-spawn-shape-manifest.sh`'s call-site population — recording
    # a lint fixture as a spawn shape, the same category error as annotating a
    # false positive with a safety pragma. `list-windows` splits the fragment
    # identically; the real corpus line is covered by the tree-wide scan.
    _expect 'a payload whose ; splits the fragment' CLEAN \
'run '\''{"tool_name":"Bash","tool_input":{"command":"tmux list-windows ; tmux kill-window"}}'\'''
    _expect 'a payload carrying TMUX_TMPDIR does not trip rule2 either' CLEAN \
'run '\''{"tool_name":"Bash","tool_input":{"command":"TMUX_TMPDIR=/tmp/x tmux kill-server"}}'\'''
    # THE POTENCY CONTROL, inline. Every assertion above is absence-shaped, and
    # an absence-shaped assertion is also satisfied by a scanner that has gone
    # blind. These two say the same predicate still SEES a real kill, including
    # the `\;` sequence and abbreviation support #892 added — so "clean" above
    # means "read and acquitted", not "never read".
    _expect 'a REAL kill on the next line is still caught (potency)' \
        rule1-killserver-unscoped \
'run '\''{"tool_name":"Bash","tool_input":{"command":"tmux kill-server"}}'\''
tmux kill-server'
    _expect 'a REAL \; sequence beside a payload is still caught (potency)' \
        rule1-killserver-unscoped \
'run '\''{"tool_input":{"command":"tmux kill-server"}}'\''
tmux list-windows \; kill-ser'

    # === 7. WHICH FILES — the enumeration itself ===========================
    #
    # Sections 1-6 all plant `*.sh` files, so every one of them passed while
    # the lint was blind to `monitor/ng` (your-org/nexus-code#792). A scanner is
    # only as good as its file list, and until now nothing tested the file list.
    #
    # Every assertion here is POSITIVE — it names something that must be FOUND.
    # An enumerator broken into returning nothing fails all of them, rather than
    # passing them the way an absence-shaped assertion would. That distinction is
    # the whole of `#793`(b), applied here at the point it was learned rather
    # than after the next skeptic finds it again.
    echo "=== the FILE LIST (your-org/nexus-code#792) ==="

    _plant() {   # _plant <label> <filename> <want-rule|CLEAN> <body>
        local label="$1" fname="$2" want="$3" body="$4" d
        d=$(mktemp -d "$tmp/plant.XXXXXX"); printf '%s\n' "$body" > "$d/$fname"
        chmod +x "$d/$fname"
        out=$(scan "$d" 2>&1)
        if [[ "$want" == CLEAN ]]; then
            _ck "$label" $([[ -z "$out" ]] && echo 0 || echo 1) \
                "expected unscanned, got: $out"
        else
            _ck "$label" $(grep -qF ":$want:" <<<"$out" && echo 0 || echo 1) \
                "got: ${out:-<clean — THE FILE WAS NOT READ AT ALL>}"
        fi
    }

    # THE HEADLINE. An EXTENSIONLESS executable, under a name no enumerator in
    # this repo has ever heard of, carrying a real server-killer. If this fails,
    # the guard is blind in exactly the way it was blind to `monitor/ng`. It is
    # also the answer to "does a file added tomorrow get covered automatically":
    # nothing anywhere names `brand-new-tool`.
    _plant 'an EXTENSIONLESS shebang executable is SCANNED (the #792 hole)' \
        'brand-new-tool' rule1-killserver-unscoped \
'#!/usr/bin/env bash
tmux kill-server 2>/dev/null || true'

    # DISCRIMINATION. Byte-identical hazard, but no shebang, no extension and no
    # startup-file name — not a shell file, and so NOT scanned. Without this the
    # assertion above would also be satisfied by an enumerator that simply read
    # every file on disk, which is not a derivation either.
    _plant 'a NON-script file with the same bytes is NOT scanned' \
        'notes-about-tmux' CLEAN \
'tmux kill-server 2>/dev/null || true'

    # Arm 3: a zsh startup file has neither an extension nor a shebang, because
    # the shell sources it by NAME. Four live ones sit in `monitor/shellenv/`.
    _plant 'a zsh STARTUP file (.zshenv - no extension, no shebang) is scanned' \
        '.zshenv' rule3-untargeted-kill \
'tmux -L iso kill-window'

    # `#!/usr/bin/env -S bash -e` — the shape that defeats a naive "second word
    # after env" read, which would take the interpreter to be `-S` and drop the
    # file silently.
    _plant 'an env -S shebang resolves to its real interpreter' \
        'wrapped-tool' rule1-killserver-unscoped \
'#!/usr/bin/env -S bash -e
tmux kill-server'

    # And the population on the REAL tree, positively. `monitor/ng` is the file
    # `#792` is named for; `.zshenv` is the arm-3 member. Both asserted by
    # PRESENCE, so an empty enumeration reds here too.
    local real_list
    real_list=$(files0 "$repo_root/monitor" | tr '\0' '\n')
    _ck 'monitor/ng is in the scanned population' \
        $(grep -qx "$repo_root/monitor/ng" <<<"$real_list" && echo 0 || echo 1) \
        "ng absent from a population of $(grep -c . <<<"$real_list") files"
    _ck 'monitor/shellenv/.zshenv is in the scanned population' \
        $(grep -qx "$repo_root/monitor/shellenv/.zshenv" <<<"$real_list" && echo 0 || echo 1) \
        "the arm-3 startup files are absent"

    # The floor. Deliberately far below the true count (~439) so deleting files
    # never trips it: a broken-enumerator alarm, not an inventory to keep
    # current. That is why a floor is the right shape and a recorded count is
    # not — nobody is ever tempted to bump this reflexively.
    _ck 'the population clears its non-vacuity floor' \
        $(shf_require_floor "$repo_root/monitor" shell 300 \
            'lint-no-tmux-server-kill' && echo 0 || echo 1)

    # === 8. manifest =======================================================
    echo "=== pragma manifest ==="
    local n expected
    n=$(count_pragmas "$repo_root/monitor")
    expected="${LINT_TMUX_EXPECTED_PRAGMAS:-2}"
    _ck "pragma count is $expected as expected" \
        $([[ "$n" == "$expected" ]] && echo 0 || echo 1) \
        "found $n — an exemption was added or removed; review it, then update LINT_TMUX_EXPECTED_PRAGMAS"

    printf '\n  %d pass / %d fail\n' "$passes" "$fails"
    (( fails == 0 )) || return 1
    echo "lint-no-tmux-server-kill: SELFTEST OK"
    return 0
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    --selftest) selftest; exit $? ;;
    --manifest)
        t="${2:-$repo_root/monitor}"
        echo "scanned:  $t"
        echo "pragmas:  $(count_pragmas "$t")"
        echo "files:    $(files0 "$t" | tr -dc '\0' | wc -c | tr -d ' ') shell files (derived; see WHICH FILES)"
        files0 "$t" \
          | xargs -0 grep -nHE '(^|[[:space:]])kill-(server|session|window|pane)([[:space:]]|$)' 2>/dev/null \
          | grep -vE ':[0-9]+:[[:space:]]*#' | sed 's/^/  call: /'
        exit 0 ;;
    -h|--help) sed -n '2,80p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
esac

target="${1:-$repo_root/monitor}"
[[ -d "$target" ]] || { echo "not a directory: $target" >&2; exit 2; }

hits=$(scan "$target")
if [[ -n "$hits" ]]; then
    explain
    echo "  Offending lines:" >&2
    sed 's/^/    /' <<<"$hits" >&2
    exit 1
fi
echo "lint-no-tmux-server-kill: clean ($target)"
