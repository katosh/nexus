#!/usr/bin/env bash
# test-claude-md-window-key-vocabulary.sh — give CLAUDE.md's
# WINDOW-KEY-VOCABULARY block a READER (your-org/nexus-code#1239).
#
# Run: bash monitor/watcher/test-claude-md-window-key-vocabulary.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. `#1239` reported WINDOW-KEY-VOCABULARY as the one
# BEGIN/END pair in CLAUDE.md read by NOTHING — "markers with no reader are
# worse than no markers, because they signal a guarantee nobody provides".
#
# ITS DETECTION PREDICATE HAS SINCE GONE STALE IN THE DIRECTION THAT DECLARES
# THE DEFECT FIXED, and that is the part worth carrying. `#1239` measured
# `git grep WINDOW-KEY-VOCABULARY` -> two hits, both in CLAUDE.md. At
# `5bd6d400` that command returns THREE files, so the issue's own test now
# answers "it has a reader". It does not: the third hit is
# `monitor/watcher/test-pane-state-claude-identity.sh:620`, a COMMENT that
# mentions the block while asserting something else. A name-mention predicate
# cannot separate a reader from a citation, and it fails toward "covered" —
# the same shape as every finding in the bullet list this block lives in.
#
# WHAT IS PINNED, and the block was chosen for it: WINDOW-KEY-VOCABULARY is
# the only marker pair carrying ZERO fence lines. There is no command to
# extract and run, so the "execute the fenced block" contract every sibling
# suite uses does not apply. What it carries instead is a HAND-MAINTAINED
# ENUMERATION inside prose — three tool/exit-code pairs — which is exactly the
# construct `#1239` says to DERIVE rather than assert:
#
#     "Wherever a guarded entry hand-maintains a LIST or a COUNT, either
#      DERIVE it from a tool and assert set-equality both ways, or mark it
#      explicitly non-exhaustive."
#
# So the document supplies the CLAIM and the tools supply the TRUTH: §2 parses
# the three exit codes out of the block text and §3 drives each tool against a
# planted ambiguity fixture, asserting the OBSERVED status equals the
# DOCUMENTED one. An edit to the prose that changes a number reds here; so
# does a tool that changes its refusal code without the prose following.
#
# THE FIXTURE IS A STUB, NOT A LIVE TMUX, AND THAT IS DELIBERATE. The
# ambiguity these tools refuse is a window NAMED `1` coexisting with a
# DIFFERENT window at INDEX `1`. Building that in a real server is possible and
# costs a socket — and a tmux socket path holds 107 bytes, which is the
# `#991` trap that mis-attributed five failures. `resolve_window_key` reaches
# tmux only through `list-windows -F`, so a PATH-front stub answering that one
# call reproduces the collision exactly, with no socket and no ceiling.
#
# NON-VACUITY AND POSITIVE CONTROLS, because "the tool exited N" is worthless
# without evidence the instrument could have seen otherwise:
#   Control A — the block extracts non-empty, and the three claims parse. A
#               botched extraction would otherwise pass by asserting nothing.
#   Control B — the stub is REACHED. Each tool's invocation is required to
#               have called `list-windows`, so a tool that never consulted the
#               fixture cannot contribute a green.
#   Control C — an UNAMBIGUOUS key does NOT take the ambiguity arm. Without
#               it, a tool that refused everything unconditionally would score
#               three passes.
#
# COVERAGE BOUNDARY, stated because one of the three claims is genuinely
# weaker than the other two. `paste-followup.sh` exits 1 on ambiguity AND on
# every other refusal it makes — measured here: an unresolvable window also
# exits 1. So its exit code does NOT discriminate, and asserting the number
# alone would be satisfied by a tool that had lost the check entirely. §3
# therefore asserts the AMBIGUOUS DIAGNOSTIC alongside the status for that
# tool, and the diagnostic is the load-bearing half. `pane-state.sh` (2) and
# `_tmux-window.sh key` (4) do discriminate; their codes are asserted as
# stated. NOT covered: the block's prose about WHICH resolver each tool calls
# is pinned structurally by §5 (a CALL-shaped grep for the named function,
# not a mention-shaped one — see its own note), not by
# execution — that sentence records a claim that was once FALSE here, and a
# structural check is what makes its recurrence red.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

# `--population`: the files whose BYTES decide this suite's verdict
# (monitor/_guard_population.sh). The block it reads, plus all three tools it
# DRIVES — an edit to any of their refusal paths changes the answer here.
# shellcheck disable=SC1091
. "$REPO_ROOT/monitor/_guard_population.sh"
gp_population() {
    printf '%s\n' "$CLAUDE_MD"
    printf '%s\n' "$REPO_ROOT/monitor/_tmux-window.sh"
    printf '%s\n' "$REPO_ROOT/monitor/pane-state.sh"
    printf '%s\n' "$REPO_ROOT/monitor/paste-followup.sh"
}
gp_handle "$@"
bash "$(dirname "${BASH_SOURCE[0]}")/claude-md-block-coverage.sh" WINDOW-KEY-VOCABULARY   # the entry's UNCHECKED share, in this suite's own output (#1239)

WORK=$(mktemp -d -t nexus-wkv-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
echo '=== §1 Control A: the block extracts, non-empty, and its claims parse ==='
# ===========================================================================
BEGIN_MARK='<!-- BEGIN WINDOW-KEY-VOCABULARY -->'
END_MARK='<!-- END WINDOW-KEY-VOCABULARY -->'

if [[ -r "$CLAUDE_MD" ]]; then
    ok "CLAUDE.md is readable at $CLAUDE_MD"
else
    bad "CLAUDE.md is readable" "not readable at $CLAUDE_MD"
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi

BLOCK=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD")
block_lines=$(printf '%s\n' "$BLOCK" | grep -c . || true)
[[ "$block_lines" -ge 10 ]] && ok "the block extracts non-empty ($block_lines lines)" \
    || bad "the block extracts non-empty" "got $block_lines lines — markers moved or removed"

if (( FAIL > 0 )); then
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi

# ===========================================================================
echo '=== §2 The DOCUMENT supplies the claims — parsed, never hard-coded ==='
# ===========================================================================
# Each claim is spelled `**`<tool>` exits <n>**` or, for the third,
# `**`monitor/_tmux-window.sh key`\nexits 4**` across a line break. Normalise
# the block to one line first so a reflow of the paragraph does not change the
# parse — a reflow is not a semantic edit and must not red this suite.
FLAT=$(printf '%s\n' "$BLOCK" | tr '\n' ' ' | tr -s ' ')

claim_of() {
    # $1 = tool spelling as it appears in the prose. Prints the documented code.
    #
    # `sed -n '1p'` AND NOT `head -1`, DELIBERATELY. This file runs under
    # `set -o pipefail`, and `head` exits as soon as its count is met, so the
    # upstream `grep` takes SIGPIPE and the pipeline's status is 141 — the
    # early-exit-reader class (your-org/nexus-code#622, #1130). A bare
    # `sed -n '<n>p>'` DRAINS its input and is not a site; nor is `tail`, which
    # must read to EOF by definition. Caught here by
    # `test-early-exit-reader-manifest.sh` before this branch was pushed.
    printf '%s' "$FLAT" \
        | grep -oE "\`$1\`\*{0,2} *\*{0,2}exits [0-9]+" \
        | grep -oE '[0-9]+$' \
        | sed -n '1p'
}
DOC_PANE=$(claim_of 'pane-state\.sh')
DOC_PASTE=$(claim_of 'paste-followup\.sh')
DOC_TW=$(claim_of 'monitor/_tmux-window\.sh key')

# The parse itself is a positive control: a claim that did not parse comes back
# EMPTY, and an empty string compared against an observed rc would pass nothing
# but would also assert nothing. Require all three to be digits FIRST — an
# emptiness check is a presence test wearing a validity test's name (#1203).
for pair in "pane-state.sh:$DOC_PANE" "paste-followup.sh:$DOC_PASTE" "_tmux-window.sh key:$DOC_TW"; do
    _t="${pair%:*}"; _v="${pair##*:}"
    if [[ "$_v" =~ ^[0-9]+$ ]]; then
        ok "the block states an exit code for \`$_t\` (documented: $_v)"
    else
        bad "the block states an exit code for \`$_t\`" \
            "parsed [$_v] — the prose no longer spells the claim, so nothing below is checking it"
    fi
done

if (( FAIL > 0 )); then
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi

# ===========================================================================
echo '=== §3 The TOOLS supply the truth — driven against a planted collision ==='
# ===========================================================================
# THE FIXTURE. A window NAMED `1` sits at index 3; a DIFFERENT window (`alpha`)
# sits at INDEX 1. So the key `1` is both a name and another window's index —
# the exact input all three tools are documented to REFUSE rather than guess.
#
# The stub dispatches on FORMAT DEFENSIVELY, and that word is doing real work:
# at this ref the arm is NOT load-bearing, and an earlier version of this
# comment presented it as a hard-won necessity. Measured (#1239 skeptic S-4a):
# all three drives resolve through `resolve_window_key`, which requests
# `#{window_index}|#{window_name}` (`_tmux-window.sh:318`), and each makes
# exactly ONE `list-windows` call. `resolve_window_id` (`:235`) is the only
# `#{window_id}` caller and is on none of these paths — so collapsing the stub
# to a single shape with no `case` at all still yields ALL TESTS PASSED. The id
# arm is kept so a caller that one day resolves by id does not silently receive
# an index-shaped answer; it is insurance, not a lesson this fixture depends
# on. (The rc-3 "tmux would not answer" failure IS real and did happen while
# building this fixture — from a stub answering the wrong SHAPE, not from the
# absence of the dispatch.)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'called %s\n' "$*" >> "${TMUX_STUB_LOG:?}"
if [ "$1" = "list-windows" ]; then
    fmt=""; prev=""
    for a in "$@"; do [ "$prev" = "-F" ] && fmt="$a"; prev="$a"; done
    case "$fmt" in
        *window_id*)    printf '@3|1\n@1|alpha\n' ;;
        *window_index*) printf '3|1\n1|alpha\n'   ;;
        *)              printf '3|1\n1|alpha\n'   ;;
    esac
    exit 0
fi
exit 0
STUB
chmod +x "$WORK/bin/tmux"

# drive <label> <expected-rc> <cmd...>  — records rc, stderr, and stub reach.
drive() {
    local label="$1" want="$2"; shift 2
    TMUX_STUB_LOG="$WORK/stub.$label.log"; : > "$TMUX_STUB_LOG"
    export TMUX_STUB_LOG
    local err="$WORK/err.$label" rc
    PATH="$WORK/bin:$PATH" "$@" >/dev/null 2>"$err"
    rc=$?
    DRIVE_RC="$rc"
    DRIVE_ERR=$(cat "$err")
    DRIVE_REACHED=$(grep -c 'called list-windows' "$TMUX_STUB_LOG" || true)
}

# --- pane-state.sh: documented to exit 2, and its code DISCRIMINATES --------
drive pane "$DOC_PANE" bash "$REPO_ROOT/monitor/pane-state.sh" 1
[[ "$DRIVE_REACHED" -gt 0 ]] && ok "Control B: pane-state.sh consulted the planted fixture" \
    || bad "Control B: pane-state.sh consulted the planted fixture" \
           "list-windows never called — the green below would be about nothing"
assert_eq "pane-state.sh refuses the ambiguous key with the DOCUMENTED status" \
    "$DRIVE_RC" "$DOC_PANE"

# --- _tmux-window.sh key: documented to exit 4, and it DISCRIMINATES --------
drive tw "$DOC_TW" bash "$REPO_ROOT/monitor/_tmux-window.sh" key 1
[[ "$DRIVE_REACHED" -gt 0 ]] && ok "Control B: _tmux-window.sh key consulted the planted fixture" \
    || bad "Control B: _tmux-window.sh key consulted the planted fixture" \
           "list-windows never called"
assert_eq "_tmux-window.sh key refuses the ambiguous key with the DOCUMENTED status" \
    "$DRIVE_RC" "$DOC_TW"

# --- paste-followup.sh: documented to exit 1 — and 1 does NOT discriminate --
# See the COVERAGE BOUNDARY note in the header. The status is asserted because
# the block states it; the DIAGNOSTIC is asserted because the status alone is
# satisfied by a tool that lost the check. Control C below measures the
# non-discrimination rather than merely claiming it.
drive paste "$DOC_PASTE" bash "$REPO_ROOT/monitor/paste-followup.sh" 1 --message 'fixture'
[[ "$DRIVE_REACHED" -gt 0 ]] && ok "Control B: paste-followup.sh consulted the planted fixture" \
    || bad "Control B: paste-followup.sh consulted the planted fixture" \
           "list-windows never called"
assert_eq "paste-followup.sh refuses the ambiguous key with the DOCUMENTED status" \
    "$DRIVE_RC" "$DOC_PASTE"
case "$DRIVE_ERR" in
    *"ambiguous window key"*)
        ok "…and says so — the AMBIGUOUS diagnostic is the discriminating half" ;;
    *)  bad "…and says so — the AMBIGUOUS diagnostic is the discriminating half" \
            "exit $DRIVE_RC carries no ambiguity diagnostic; this tool exits 1 on every refusal, so the status alone proves nothing" ;;
esac

# ===========================================================================
echo '=== §4 Control C: an UNAMBIGUOUS key does NOT take the ambiguity arm ==='
# ===========================================================================
# Without this, a tool that refused every input unconditionally would score a
# clean sweep above. `alpha` is a plain name, present in the fixture, colliding
# with no index.
#
# AND THE KEY SHAPE IS LOAD-BEARING, WHICH THIS SUITE LEARNED BY SURVIVING A
# MUTANT. `alpha` alone is NOT a sufficient control: `pane-state.sh` enters its
# ambiguity arm only for a key matching `^[0-9]+$` or `^[^:]+:[0-9]+$`, so a
# non-numeric key never reaches that code at all. Broadening the refusal to
# `if true` — a tool that refuses EVERY numeric key — left this suite GREEN
# when the control was `alpha`-only. The discriminating control has to be
# NUMERIC and UNAMBIGUOUS: `3` is an index in the fixture (the window named
# `1` sits there) and is no window's NAME, so it enters the arm and must come
# out of it unrefused. That is the difference between a control that proves
# the check works and one that proves the check is unreachable.
drive pane_num 0 bash "$REPO_ROOT/monitor/pane-state.sh" 3
case "$DRIVE_ERR" in
    *"AMBIGUOUS"*)
        bad "Control C: pane-state.sh does NOT cry ambiguity on a NUMERIC unambiguous key" \
            "it refused \`3\`, which is an index and no window's name — the ambiguity arm fires unconditionally" ;;
    *)  ok "Control C: pane-state.sh does NOT cry ambiguity on a NUMERIC unambiguous key" ;;
esac

drive pane_ok 0 bash "$REPO_ROOT/monitor/pane-state.sh" alpha
case "$DRIVE_ERR" in
    *"AMBIGUOUS"*|*"ambiguous"*)
        bad "Control C: pane-state.sh does NOT cry ambiguity on an unambiguous key" \
            "it refused \`alpha\` too — the §3 green is unconditional refusal, not a working check" ;;
    *)  ok "Control C: pane-state.sh does NOT cry ambiguity on an unambiguous key" ;;
esac

drive tw_ok 0 bash "$REPO_ROOT/monitor/_tmux-window.sh" key alpha
assert_eq "Control C: _tmux-window.sh key resolves the unambiguous name at rc 0" \
    "$DRIVE_RC" "0"

drive tw_num 0 bash "$REPO_ROOT/monitor/_tmux-window.sh" key 3
assert_eq "Control C: _tmux-window.sh key resolves a NUMERIC unambiguous key at rc 0" \
    "$DRIVE_RC" "0"

# THE NON-DISCRIMINATION, MEASURED RATHER THAN ASSERTED. `nosuchwindow` is not
# ambiguous; paste-followup must still exit with the same 1. This is the
# evidence behind the header's coverage boundary — it is a documented property
# of this suite's weakest claim, so it is checked, not written down and hoped.
drive paste_other 1 bash "$REPO_ROOT/monitor/paste-followup.sh" nosuchwindow --message 'fixture'
if [[ "$DRIVE_RC" == "$DOC_PASTE" ]]; then
    ok "Control C: paste-followup.sh exits $DOC_PASTE on a NON-ambiguous refusal too — its status does not discriminate, which is why §3 asserts the diagnostic"
else
    bad "Control C: paste-followup.sh's status does not discriminate" \
        "a non-ambiguous refusal exited $DRIVE_RC, not $DOC_PASTE — the header's coverage boundary is now WRONG and should be narrowed, not deleted"
fi

# ===========================================================================
echo '=== §5 The sentence that was once FALSE here, pinned structurally ==='
# ===========================================================================
# The block says, in as many words, that "both go through `resolve_window_key`"
# was written into it once while being FALSE for pane-state.sh. The claim it
# replaced it with is checkable by construct: paste-followup resolves via
# `resolve_window_key`; pane-state resolves a NAME via `resolve_window_index`
# and uses `resolve_window_key` for the ambiguity check.
# A CALL, NOT A MENTION — and the weaker predicate SURVIVED a mutant here.
# The first cut asked `grep -c <name> > 0`, which counts the identifier
# ANYWHERE, comments included. Both files discuss these resolvers in comments
# BESIDE the call, so deleting the real call at `pane-state.sh:3067` left the
# count at 2 and this arm GREEN — while its own failure string claims "the
# block describes a call graph that no longer exists", which is precisely what
# the deletion had made true. An `ok` label reading "names" was honest; the
# `bad` string asserted more than the predicate could support, and that gap is
# the whole defect. So the predicate is a CALL: the identifier followed by
# whitespace and a quoted argument, on a line that is not a comment.
_calls() { grep -qE "^[[:space:]]*[^#]*(^|[^[:alnum:]_])$1[[:space:]]+\"" "$REPO_ROOT/monitor/$2"; }
_calls 'resolve_window_key' paste-followup.sh \
    && ok "paste-followup.sh CALLS resolve_window_key, as the block says" \
    || bad "paste-followup.sh CALLS resolve_window_key, as the block says" \
           "it does not — the block describes a call graph that no longer exists"
_calls 'resolve_window_index' pane-state.sh \
    && ok "pane-state.sh CALLS resolve_window_index, as the block says" \
    || bad "pane-state.sh CALLS resolve_window_index, as the block says" "it does not"
_calls 'resolve_window_key' pane-state.sh \
    && ok "pane-state.sh ALSO CALLS resolve_window_key for the ambiguity check" \
    || bad "pane-state.sh ALSO CALLS resolve_window_key for the ambiguity check" \
           "it does not — which is the precise error the block records having made once"

# NEGATIVE CONTROLS for the predicate, because a predicate that matched
# everything would make the three greens above worthless. Both are measured
# facts at this ref, not hypotheticals.
if _calls 'resolve_window_id' pane-state.sh; then
    bad "Control D: the call predicate does NOT match a resolver pane-state.sh never calls" \
        "it matched resolve_window_id, which is DEFINED in _tmux-window.sh and called nowhere here — the predicate accepts too much"
else
    ok "Control D: the call predicate does NOT match a resolver pane-state.sh never calls"
fi
if grep -qE "^[[:space:]]*[^#]*(^|[^[:alnum:]_])resolve_window_key[[:space:]]+\"" "$CLAUDE_MD"; then
    bad "Control E: the call predicate does NOT fire on PROSE naming the resolver" \
        "it matched CLAUDE.md, which names resolve_window_key three times and calls it never"
else
    ok "Control E: the call predicate does NOT fire on PROSE naming the resolver"
fi

# ===========================================================================
# EXPECTED-ASSERTION COUNT (your-org/nexus-code#807). A suite that aborts
# early prints a clean-looking pass line for the assertions it did reach.
EXPECTED_ASSERTIONS=22
echo
if (( PASS + FAIL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS" >&2
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
