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
#      The tmpdir may be set ON the call (`TMUX_TMPDIR=x tmux …`) or by an
#      EARLIER command on the same line (`( export TMUX_TMPDIR=x; tmux … )`,
#      `export TMUX_TMPDIR=x; tmux …`, `&&`, a bare assignment) — the last two
#      were BLIND until your-org/nexus-code#1646. An assignment on an EARLIER
#      LINE is not connected: rule2 is per line (see _tmux_kill_scan.awk).
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
# ONE NARROW EXCEPTION, with its own token and its own pinned count
# (your-org/nexus-code#1646):
#
#     ( export TMUX_TMPDIR=…; nx_write_tmux_shim … )   # tmux-shim-writer: <why>
#
# exempts rule2 ONLY where the command word is exactly `nx_write_tmux_shim`.
# That function is not a tmux invocation — it reads TMUX_TMPDIR to BAKE it into
# a shim of the form `env -u TMUX TMUX_TMPDIR=<dir> <real tmux> -L <sock>` — and
# reaches rule2 only because the command-word test is a substring match on
# "tmux". On a real `tmux`/`"$REAL_TMUX"` call the token exempts nothing.
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
#
# `ignored-under-monitor` (your-org/nexus-code#1594): the GITIGNORED files under
# `monitor/` are read too — an ignored path is unreviewed by definition, and the
# root `.gitignore` ignores `bin/`, `logs/`, `.config/` … at any depth.
files0() {   # <root> -> NUL-separated shell files, minus this lint itself
    local f
    shf_find0 "$1" shell ignored-under-monitor | while IFS= read -r -d '' f; do
        [[ "${f##*/}" == "$self_base" ]] && continue
        printf '%s\0' "$f"
    done
}

scan_file() { awk -f "$AWK_SCAN" "$1" 2>/dev/null | sed "s|^|$1:|"; }

# One awk over the whole population (`with_file=1` prefixes FILENAME, the same
# `<file>:` scan_file's sed adds), in files0's order. The per-file form forked
# an awk and a sed per file: 22 s a call at load ~50, and the gate calls it
# twice per run. Output is byte-identical; see _tmux_kill_scan.awk's header.
#
# FAIL CLOSED (skeptic B2 on PR #1630). gawk ABORTS at the first file it cannot
# open (rc 2, `fatal: cannot open file`), so every LATER file in that batch goes
# unscanned. Discarding the status turned an unreadable or vanished file into a
# `clean` verdict that skipped a real offender (measured: a mode-000 `0aaa.sh`
# enumerated before an unscoped kill-server in `zbad.sh` -> rc 0 "clean"; the
# per-file form lost only the bad file). So the diagnostic is NOT discarded and
# a non-zero pipeline status is a refusal (rc 3 here; the caller exits 2),
# never a clean scan. `set -o pipefail` (above) makes the status the pipeline's.
scan() {
    files0 "$1" | xargs -0 -r awk -v with_file=1 -f "$AWK_SCAN" || {
        local rc=$?
        printf 'lint-no-tmux-server-kill: SCAN FAILED under %s (rc %d): a file could not be read or vanished mid-scan, so later files were NOT scanned. Refusing to report clean.\n' "$1" "$rc" >&2
        return 3
    }
}

# THE PRAGMA COUNTS ARE THE SCANNER'S OWN EXEMPTION DECISIONS
# (your-org/nexus-code#1650 N2). Each counter used to be a second regex over the
# raw text, beside the scanner's matcher, and the two disagreed: the scanner
# exempted `"nx_write_tmux_shim"` and `exec nx_write_tmux_shim` while the
# counter saw 0, so a shim-writer exemption could be added without moving the
# pin (and `kill-ser`/`killp` under `# tmux-scoped:` likewise). The scanner now
# emits one `exempt-<kind>` marker per line on which it GRANTS that exemption,
# and the counters count those markers — one matcher, by construction. A pragma
# on a line where nothing needed exempting is no longer counted: it grants
# nothing. FAIL CLOSED: a scan that could not complete prints `ERR`, which can
# never equal a pinned number.
count_exemptions() {   # <root> <kind: shim-writer|tmux-scoped>
    local out
    out=$(files0 "$1" | xargs -0 -r awk -v with_file=1 -v emit_exempt=1 -f "$AWK_SCAN") \
        || { echo ERR; return 1; }
    grep -cE "^[^:]*:[0-9]+:exempt-$2:" <<<"$out" || true
}
count_shimw_pragmas() { count_exemptions "$1" shim-writer; }
count_pragmas()       { count_exemptions "$1" tmux-scoped; }

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
  Pragmas are counted and pinned by --selftest. They never exempt rule2/rule4,
  except `# tmux-shim-writer:` on an nx_write_tmux_shim call (rule2 only).
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

    # === 2b. an UNREADABLE file must not make the scan report clean =======
    # (skeptic B2 on PR #1630) The batched awk aborts at the first file it
    # cannot open; everything after it went unscanned and the lint said clean.
    # The skeptic's fixture: a mode-000 file enumerated BEFORE a real offender.
    echo "=== an unreadable file makes the scan REFUSE, never report clean ==="
    local ud; ud=$(mktemp -d "$tmp/unread.XXXXXX")
    printf '#!/bin/bash\necho hi\n' > "$ud/0aaa.sh"; chmod 000 "$ud/0aaa.sh"
    printf '#!/bin/bash\ntmux kill-server\n' > "$ud/zbad.sh"
    local urc=0; out=$(scan "$ud" 2>&1) || urc=$?
    _ck "the batched scan REFUSES (non-zero) when a file cannot be read" \
        $([[ "$urc" != 0 ]] && grep -qF 'SCAN FAILED' <<<"$out" && echo 0 || echo 1) "rc=$urc out=$out"
    urc=0; out=$(bash "$self_dir/$self_base" "$ud" 2>&1) || urc=$?
    _ck "…and the lint EXITS 2 (refused), never 'clean'" \
        $([[ "$urc" == 2 ]] && ! grep -qF ': clean' <<<"$out" && echo 0 || echo 1) "rc=$urc out=$out"
    chmod 600 "$ud/0aaa.sh"

    # === 3. the hazard beyond kill-server ==================================
    echo "=== server-ending operations that are not kill-server ==="
    _expect 'untargeted kill-window' rule3-untargeted-kill 'tmux -L iso kill-window'
    # The awk's per-line PREFILTER skips a line with no "tmux" once is_tmux_word's
    # quote/brace set is deleted. These two pin its edges: the word is only
    # "tmux" AFTER that deletion, and only in lower case (bundle-0923).
    _expect 'a quote-split tmux word still reaches the rules' rule1-killserver-unscoped \
't"mu"x kill-server'
    _expect 'an UPPER-case tmux variable still reaches the rules' rule3-untargeted-kill \
'"$TMUX_CMD" kill-window'
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

    # === 5b. TMUX_TMPDIR set by an EARLIER command on the line (#1646) =======
    # Every hazard shape below scanned CLEAN before #1646; each is a potency
    # plant for the carrier arm. The controls pin the over-refusal direction.
    echo "=== TMUX_TMPDIR carried from an earlier command on the line (#1646) ==="
    _expect 'subshell: ( export TMUX_TMPDIR=…; tmux … )' rule2-tmux-tmpdir-insufficient \
'( export TMUX_TMPDIR="$T"; tmux new-session -d -s x )'
    _expect 'chained: export TMUX_TMPDIR=…; tmux …' rule2-tmux-tmpdir-insufficient \
'export TMUX_TMPDIR="$T"; tmux new-session -d -s x'
    _expect 'chained with &&: export TMUX_TMPDIR=… && tmux …' rule2-tmux-tmpdir-insufficient \
'export TMUX_TMPDIR="$T" && tmux kill-window -t a:0'
    _expect 'a bare assignment then tmux' rule2-tmux-tmpdir-insufficient \
'TMUX_TMPDIR="$T"; tmux new-session -d -s x'
    _expect 'an unset TMUX in an EARLIER fragment is NOT neutralisation' rule2-tmux-tmpdir-insufficient \
'( unset TMUX; export TMUX_TMPDIR="$T"; tmux new-session -d -s x )'
    _expect 'control: carried tmpdir + -L on the call is scoped' CLEAN \
'( export TMUX_TMPDIR="$T"; tmux -L iso new-session -d -s x )'
    _expect 'control: carried tmpdir + env -u TMUX on the call is scoped' CLEAN \
'export TMUX_TMPDIR="$T"; env -u TMUX tmux new-session -d -s x'
    _expect 'control: an export alone is not a tmux call' CLEAN 'export TMUX_TMPDIR="$T"'
    # The subshell OPENER standing as its own word hid the call from EVERY rule.
    _expect 'a spaced subshell: ( tmux kill-server )' rule1-killserver-unscoped '( tmux kill-server )'
    _expect 'a negated call: ! tmux kill-server' rule1-killserver-unscoped '! tmux kill-server'
    _expect 'a spaced subshell: ( tmux kill-window )' rule3-untargeted-kill '( tmux -L iso kill-window )'
    # A KEYWORD or a WRAPPER ahead of the call was returned as the command word
    # and the line scanned CLEAN under every rule (#1650 N3). One plant each.
    echo "=== a kill behind a keyword or a wrapper (#1650 N3) ==="
    _expect 'then tmux kill-server'                rule1-killserver-unscoped 'if c; then tmux kill-server; fi'
    _expect 'do tmux kill-server'                  rule1-killserver-unscoped 'for i in 1; do tmux kill-server; done'
    _expect 'else tmux kill-server'                rule1-killserver-unscoped 'if c; then :; else tmux kill-server; fi'
    _expect 'if tmux kill-server'                  rule1-killserver-unscoped 'if tmux kill-server; then :; fi'
    _expect 'while tmux kill-server'               rule1-killserver-unscoped 'while tmux kill-server; do :; done'
    _expect 'timeout N tmux kill-server'           rule1-killserver-unscoped 'timeout 5 tmux kill-server'
    _expect 'timeout -s KILL N tmux kill-server'   rule1-killserver-unscoped 'timeout -s KILL 5 tmux kill-server'
    _expect 'nohup tmux kill-server'               rule1-killserver-unscoped 'nohup tmux kill-server'
    _expect 'sudo tmux kill-server'                rule1-killserver-unscoped 'sudo tmux kill-server'
    _expect 'sudo -u root tmux kill-server'        rule1-killserver-unscoped 'sudo -u root tmux kill-server'
    _expect 'then + wrapper: then timeout 5 tmux kill-server' rule1-killserver-unscoped \
'if c; then timeout 5 tmux kill-server; fi'
    _expect 'timeout N tmux kill-window (untargeted)' rule3-untargeted-kill 'timeout 5 tmux -L iso kill-window'
    _expect 'then + carried tmpdir'                rule2-tmux-tmpdir-insufficient \
'if c; then export TMUX_TMPDIR="$T"; tmux new-session -d -s x; fi'
    _expect 'do TMUX_TMPDIR=… tmux (prefix form)'  rule2-tmux-tmpdir-insufficient \
'for i in 1; do TMUX_TMPDIR="$T" tmux new-session -d -s x; done'
    # #1121 ARM ORDER: the pin and target tests used to read the WHOLE fragment,
    # so once `sudo` is a recognised wrapper its OWN `-S` (password on stdin)
    # and `-t TYPE` would satisfy has_socket_pin / has_targeted — a permissive
    # match deciding before the deny. They read from the tmux word on now.
    _expect "sudo -S is sudo's flag, not a socket pin" rule1-killserver-unscoped 'sudo -S tmux kill-server'
    _expect "sudo -t TYPE is sudo's flag, not a target" rule3-untargeted-kill 'sudo -t unconfined_t tmux -L iso kill-window'
    # …and a carrier arm (which `continue`s) does not swallow a keyword-led call.
    _expect 'then TMUX_TMPDIR=… tmux kill-server is a CALL, not a carrier' rule1-killserver-unscoped \
'if c; then TMUX_TMPDIR="$T" tmux kill-server; fi'
    # A CASE ARM and two more wrappers (your-org/nexus-code#1652). Each scanned
    # CLEAN at 33a44f48; the first is the live instance's exact shape.
    echo "=== a kill in a case arm, or behind stdbuf / ionice (#1652) ==="
    _expect 'case W in PAT) … tmux kill-server (one line)' rule1-killserver-unscoped \
'case "$TSOCK" in "$WORK"/*) env -u TMUX TMUX_TMPDIR="$TDIR" tmux kill-server >/dev/null 2>&1 || true ;; esac'
    _expect 'a multi-line arm: PAT) tmux kill-server ;;' rule1-killserver-unscoped '    foo) tmux kill-server ;;'
    _expect 'an alternation arm: a|b) tmux kill-server ;;' rule1-killserver-unscoped '    a|b) tmux kill-server ;;'
    _expect 'a paren-led arm: (x) tmux kill-server ;;' rule1-killserver-unscoped '    (x) tmux kill-server ;;'
    _expect 'an arm with an untargeted kill-window' rule3-untargeted-kill '    *) tmux -L iso kill-window ;;'
    _expect 'stdbuf -oL tmux kill-server'          rule1-killserver-unscoped 'stdbuf -oL tmux kill-server'
    _expect 'stdbuf -o L tmux kill-server'         rule1-killserver-unscoped 'stdbuf -o L tmux kill-server'
    _expect 'ionice -c3 tmux kill-server'          rule1-killserver-unscoped 'ionice -c3 tmux kill-server'
    _expect 'ionice -c 3 -n 7 tmux kill-server'    rule1-killserver-unscoped 'ionice -c 3 -n 7 tmux kill-server'
    _expect 'control: a -S-pinned kill in a case arm is scoped' CLEAN \
'case "$TSOCK" in "$WORK"/*) env -u TMUX tmux -S "$TSOCK" kill-server >/dev/null 2>&1 || true ;; esac'
    _expect 'control: a case PATTERN named tmux is not a call' CLEAN 'case "$x" in tmux) echo hi ;; esac'
    _expect 'control: stdbuf wrapping a non-tmux command' CLEAN 'stdbuf -oL grep tmux f'
    _expect 'control: then + -L pinned is scoped'  CLEAN 'if c; then tmux -L iso kill-server; fi'
    _expect 'control: timeout + -L pinned is scoped' CLEAN 'timeout -k 2 5 tmux -L iso kill-server'
    _expect 'control: sudo -u + -S <path> is scoped' CLEAN 'sudo -u root tmux -S /tmp/iso.sock kill-server'
    _expect 'control: timeout wrapping a non-tmux command' CLEAN 'timeout 5 sleep 1'
    _expect 'control: the words as DATA' CLEAN 'echo "then tmux kill-server"'
    # THE ONE EXEMPTION, and that it cannot be moved onto a real call.
    _expect 'shim writer WITHOUT the pragma is flagged' rule2-tmux-tmpdir-insufficient \
'( export TMUX_TMPDIR="$D"; nx_write_tmux_shim "$B" "$R" s ) || exit 1'
    _expect 'shim writer WITH the pragma is exempt' CLEAN \
'( export TMUX_TMPDIR="$D"; nx_write_tmux_shim "$B" "$R" s ) || exit 1   # tmux-shim-writer: pins -L s'
    _expect 'the shim-writer pragma does NOT exempt a real tmux call' rule2-tmux-tmpdir-insufficient \
'( export TMUX_TMPDIR="$D"; tmux new-session -d -s x )   # tmux-shim-writer: nope'
    _expect '…nor a writer-NAMED lookalike' rule2-tmux-tmpdir-insufficient \
'( export TMUX_TMPDIR="$D"; my_nx_write_tmux_shim_v2 "$B" )   # tmux-shim-writer: nope'
    _expect 'the tmux-scoped pragma does NOT exempt the carried shape' rule2-tmux-tmpdir-insufficient \
'export TMUX_TMPDIR="$D"; tmux kill-window -t a:0   # tmux-scoped: nope'

    # === 5b. the COUNTER sees exactly what the SCANNER exempts (#1650 N2) ===
    # Each exempted form must be CLEAN to the scan AND counted 1 — the two
    # answers come from one decision now, and this is where that is proven.
    # The forms the old second regex missed come first.
    echo "=== every exemption the scanner grants is counted (#1650 N2) ==="
    _count_case() {   # _count_case <label> <shim-writer|tmux-scoped> <want> <line>
        local d n v
        d=$(mktemp -d "$tmp/count.XXXXXX"); printf '%s\n' "$4" > "$d/planted.sh"
        n=$(count_exemptions "$d" "$2"); v=$(scan "$d" 2>&1)
        _ck "$1 → counted $3" $([[ "$n" == "$3" ]] && echo 0 || echo 1) "counted $n"
        if [[ "$3" != 0 ]]; then
            _ck "$1 → and the scan is clean" $([[ -z "$v" ]] && echo 0 || echo 1) "got: $v"
        fi
    }
    _count_case 'a QUOTED "nx_write_tmux_shim"' shim-writer 1 \
'( export TMUX_TMPDIR="$D"; "nx_write_tmux_shim" "$B" "$R" s )   # tmux-shim-writer: pins -L s'
    _count_case 'exec nx_write_tmux_shim' shim-writer 1 \
'( export TMUX_TMPDIR="$D"; exec nx_write_tmux_shim "$B" "$R" s )   # tmux-shim-writer: pins -L s'
    _count_case 'the plain form' shim-writer 1 \
'( export TMUX_TMPDIR="$D"; nx_write_tmux_shim "$B" "$R" s )   # tmux-shim-writer: pins -L s'
    _count_case 'control: a lookalike is flagged, never counted' shim-writer 0 \
'( export TMUX_TMPDIR="$D"; my_nx_write_tmux_shim_v2 "$B" )   # tmux-shim-writer: nope'
    _count_case 'control: a pragma with NOTHING to exempt grants nothing' shim-writer 0 \
'nx_write_tmux_shim "$B" "$R" s   # tmux-shim-writer: no tmpdir on this line'
    _count_case 'an ABBREVIATED kill-ser under tmux-scoped' tmux-scoped 1 \
'"$PTMUX" kill-ser   # tmux-scoped: private shim'
    _count_case 'the killp short form under tmux-scoped' tmux-scoped 1 \
'"$PTMUX" killp   # tmux-scoped: private shim'
    _count_case 'the plain kill-server form under tmux-scoped' tmux-scoped 1 \
'"$PTMUX" kill-server   # tmux-scoped: private shim'
    # TWO exemptions on ONE line count 2 (your-org/nexus-code#1652 item 2). The
    # counter used to emit one marker per LINE, so both of these counted 1 and a
    # second exempted kill could be added beside a reviewed one unseen.
    _count_case 'TWO exempted kill-servers on one line' tmux-scoped 2 \
'"$PTMUX" kill-server; "$PTMUX" kill-server   # tmux-scoped: private shim'
    _count_case 'one pragma exempting rule1 AND rule3 (a \; sequence)' tmux-scoped 2 \
'"$PTMUX" kill-server \; kill-window   # tmux-scoped: private shim'
    _count_case 'TWO shim-writer calls on one line' shim-writer 2 \
'( export TMUX_TMPDIR="$D"; nx_write_tmux_shim "$B" "$R" s; nx_write_tmux_shim "$B" "$R" t )   # tmux-shim-writer: pins -L s/t'
    _count_case 'control: a -L-pinned kill needs no pragma, so none is counted' tmux-scoped 0 \
'tmux -L iso kill-server   # tmux-scoped: redundant'

    # === 5c. a QUOTED argument ending in `;` is a TMUX separator (#1579) ======
    # tmux ends a command at any argument whose last character is `;`, judged
    # after the shell removes quotes (#1578). The scanner used to split every
    # `;` as SHELL punctuation, tearing `'hi;'` apart so the following verb had
    # no tmux command word: measured, every quoted shape scanned CLEAN.
    echo "=== a quoted ';'-ended argument separates tmux commands (#1579) ==="
    _expect "'hi;' kill-server"          rule1-killserver-unscoped "tmux display-message 'hi;' kill-server"
    _expect '"hi;" kill-server'          rule1-killserver-unscoped 'tmux display-message "hi;" kill-server'
    _expect "the VERB slot 'list-windows;'" rule1-killserver-unscoped "tmux 'list-windows;' kill-server"
    _expect "';;' kill-server"           rule1-killserver-unscoped "tmux display-message ';;' kill-server"
    _expect "'hi;' then an untargeted kill-window" rule3-untargeted-kill "tmux display-message 'hi;' kill-window"
    _expect "a quoted ';' inside a pinned invocation stays scoped" CLEAN "tmux -L priv display-message 'hi;' kill-server"
    _expect "control: a MID-word quoted ';' is data"     CLEAN "tmux display-message 'a;b' kill-server"
    _expect "control: a quoted '\\;' is a literal ';'"   CLEAN "tmux display-message 'hi\\;' kill-server"
    _expect "control: tmux does not re-split one argument" CLEAN "tmux display-message 'x; kill-server'"
    _expect "control: 'hi;'x is ONE word not ending in ';'" CLEAN "tmux display-message 'hi;'x kill-server"
    # semisplitsk2 F6: an EMPTY quote pair glued on adds nothing to the word.
    _expect "'hi;''' (empty pair glued on) kill-server"  rule1-killserver-unscoped "tmux display-message 'hi;''' kill-server"
    _expect '"hi;""" (empty pair glued on) kill-server'  rule1-killserver-unscoped 'tmux display-message "hi;""" kill-server'
    _expect "'hi;'\"\" (mixed empty pair) kill-server"    rule1-killserver-unscoped "tmux display-message 'hi;'\"\" kill-server"
    _expect "control: 'hi;'''x — the word goes on past the empty pair" CLEAN "tmux display-message 'hi;'''x kill-server"

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

    # The UNTRACKED-AND-GITIGNORED plant case (your-org/nexus-code#1594 item 1)
    # needs a real git fixture, and a `git init` in this file is refused by the
    # cc-update no-remote-code lint (this lint is in its gated population). It
    # therefore lives in monitor/watcher/test-shell-files.sh, which runs THIS
    # lint's CLI against that fixture.

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
    # The manifest is a REVIEW RATCHET (a count that forces a human to look at
    # each new exemption), not a detector check: sections 1-7 prove the
    # detector fires. gate.sh runs the selftest with the ratchet split out
    # (LINT_TMUX_SELFTEST_SKIP_MANIFEST=1) and checks it separately via
    # --manifest-check, so a stale count is filed as repo hygiene instead of
    # refusing every candidate before a scenario runs (your-org/nexus-code#1657;
    # 2.1.283 on 2026-09-27). The unit band still runs the full selftest.
    if [[ "${LINT_TMUX_SELFTEST_SKIP_MANIFEST:-0}" == "1" ]]; then
        echo "=== pragma manifest: SKIPPED here (LINT_TMUX_SELFTEST_SKIP_MANIFEST=1) — checked by --manifest-check ==="
        printf '\n  %d pass / %d fail\n' "$passes" "$fails"
        (( fails == 0 )) || return 1
        echo "lint-no-tmux-server-kill: SELFTEST OK (detector sections; manifest ratchet split out)"
        return 0
    fi
    manifest_checks || true   # its _ck calls already counted any FAIL
    printf '\n  %d pass / %d fail\n' "$passes" "$fails"
    (( fails == 0 )) || return 1
    echo "lint-no-tmux-server-kill: SELFTEST OK"
    return 0
}

# manifest_checks — the counted-exemption ratchet (section 8), shared by
# --selftest and --manifest-check. rc 0 iff both pinned counts hold.
manifest_checks() {
    local _mfails=0
    echo "=== pragma manifest ==="
    local n expected
    n=$(count_pragmas "$repo_root/monitor")
    # 4 = cc-harness/_lib.sh (cch_tmux), test-integration/_harness.sh, and the two
    # Codex real-binary suites added by #1640/#1642 (test-codex-busy-phases.sh,
    # test-codex-worker-e2e.sh). REVIEWED for #1643: each kills through "$PTMUX",
    # written by nx_write_tmux_shim under a private TMUX_TMPDIR as
    # `env -u TMUX … <real binary> -L cxp|cxe`, and only inside [[ -x "$PTMUX" ]]
    # — the same shape as the _harness.sh exemption.
    expected="${LINT_TMUX_EXPECTED_PRAGMAS:-4}"
    [[ "$n" == "$expected" ]] || _mfails=$((_mfails + 1))
    _ck "pragma count is $expected as expected" \
        $([[ "$n" == "$expected" ]] && echo 0 || echo 1) \
        "found $n — an exemption was added or removed; review it, then update LINT_TMUX_EXPECTED_PRAGMAS"

    # The #1646 shim-writer exemption, pinned separately: the two Codex
    # real-binary suites (test-codex-busy-phases.sh, test-codex-worker-e2e.sh),
    # each `( export TMUX_TMPDIR="$SOCKDIR"; nx_write_tmux_shim … cxp|cxe )`.
    # REVIEWED for #1646: nx_write_tmux_shim writes `env -u TMUX … -L <sock>`.
    local ns nsexp
    ns=$(count_shimw_pragmas "$repo_root/monitor")
    nsexp="${LINT_TMUX_EXPECTED_SHIMW_PRAGMAS:-2}"
    [[ "$ns" == "$nsexp" ]] || _mfails=$((_mfails + 1))
    _ck "shim-writer pragma count is $nsexp as expected" \
        $([[ "$ns" == "$nsexp" ]] && echo 0 || echo 1) \
        "found $ns — a shim-writer exemption was added or removed; review it, then update LINT_TMUX_EXPECTED_SHIMW_PRAGMAS"
    (( _mfails == 0 ))
}

# pragma_files <dir> — every file carrying a counted exemption, one
# `<path><TAB><tmux-scoped><TAB><shim-writer>` per line. Derived from the
# SCANNER'S OWN exemption decisions (`emit_exempt`), the same source
# count_pragmas / count_shimw_pragmas read since #1650 N2 — so the per-file
# split can never disagree with the manifest total. gate.sh uses it to tell an
# exemption INSIDE the files it executes (a safety question) from one outside
# them (repo hygiene), for BOTH kinds (your-org/nexus-code#1657). A scan that
# fails prints nothing and returns 1: the caller then refuses (fail-closed).
pragma_files() {
    local out
    out=$(files0 "$1" | xargs -0 -r awk -v with_file=1 -v emit_exempt=1 -f "$AWK_SCAN") || return 1
    awk -F: '
        $3 == "exempt-tmux-scoped" { t[$1]++; seen[$1] = 1 }
        $3 == "exempt-shim-writer" { w[$1]++; seen[$1] = 1 }
        END { for (f in seen) printf "%s\t%d\t%d\n", f, t[f] + 0, w[f] + 0 }' <<<"$out" | sort
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    --selftest) selftest; exit $? ;;
    --manifest-check)
        passes=0; fails=0
        _ck() {  # same contract as selftest's _ck
            if (( $2 == 0 )); then printf '  PASS: %s\n' "$1"; passes=$((passes+1))
            else printf '  FAIL: %s%s\n' "$1" "${3:+ — $3}" >&2; fails=$((fails+1)); fi
        }
        manifest_checks; exit $? ;;
    --pragma-files)
        pragma_files "${2:-$repo_root/monitor}"; exit 0 ;;
    --manifest)
        t="${2:-$repo_root/monitor}"
        echo "scanned:  $t"
        echo "pragmas:  $(count_pragmas "$t")"
        echo "shim-writer pragmas: $(count_shimw_pragmas "$t")"
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

hits=$(scan "$target") || {
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    echo "lint-no-tmux-server-kill: REFUSED — the scan did not complete (see above); this is NOT a clean result" >&2
    exit 2
}
if [[ -n "$hits" ]]; then
    explain
    echo "  Offending lines:" >&2
    sed 's/^/    /' <<<"$hits" >&2
    exit 1
fi
echo "lint-no-tmux-server-kill: clean ($target)"
