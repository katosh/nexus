#!/usr/bin/env bash
# monitor/watcher/test-bash-footgun-guard.sh
#
# Unit tests for the just-in-time footgun hook (proposal: worker-floor
# redesign). Verifies that bash-footgun-guard.sh injects the right
# reminder as PreToolUse `additionalContext` when a worker's Bash
# command matches a footgun, stays silent otherwise, dedups per
# (window, tag), and passes benign / non-Bash calls through.

set -u
_test_dir=$(cd "$(dirname "$0")" && pwd)
HOOK="$_test_dir/../hooks/bash-footgun-guard.sh"
CONF="$_test_dir/../bash-footgun-patterns.conf"

PASS=0; FAIL=0
STATE=$(mktemp -d)
trap 'rm -rf "$STATE"' EXIT
export NEXUS_ROOT="$_test_dir/../.."
export NEXUS_STATE_DIR="$STATE"
export NEXUS_FOOTGUN_PATTERNS="$CONF"
export NEXUS_WORKER_WINDOW="footgun-test"

# run <payload-json> → prints hook stdout, sets RC
run() { OUT=$(printf '%s' "$1" | bash "$HOOK"); RC=$?; }

assert_ctx() { # <desc> <substring>  (additionalContext must contain substring, exit 0)
    if [[ $RC -eq 0 && "$OUT" == *"$2"* ]]; then
        printf '  PASS: %s\n' "$1"; PASS=$((PASS+1))
    else
        printf '  FAIL: %s (rc=%s out=%q)\n' "$1" "$RC" "$OUT" >&2; FAIL=$((FAIL+1))
    fi
}
assert_ctx_absent() { # <desc> <substring>  (fired, but must NOT contain substring)
    if [[ $RC -eq 0 && -n "$OUT" && "$OUT" != *"$2"* ]]; then
        printf '  PASS: %s\n' "$1"; PASS=$((PASS+1))
    else
        printf '  FAIL: %s (rc=%s out=%q)\n' "$1" "$RC" "$OUT" >&2; FAIL=$((FAIL+1))
    fi
}
assert_silent() { # <desc>  (no stdout, exit 0)
    if [[ $RC -eq 0 && -z "$OUT" ]]; then
        printf '  PASS: %s\n' "$1"; PASS=$((PASS+1))
    else
        printf '  FAIL: %s (rc=%s out=%q)\n' "$1" "$RC" "$OUT" >&2; FAIL=$((FAIL+1))
    fi
}

echo '=== conf-driven footgun matches inject additionalContext ==='
run '{"tool_name":"Bash","tool_input":{"command":"pkill -f my-task-marker"}}'
assert_ctx "pkill -f fires self-kill reminder" "self-kill"
run '{"tool_name":"Bash","tool_input":{"command":"cd a && git push origin x"}}'
assert_ctx "git push fires wrong-remote reminder" "git -C <clone> push"
run '{"tool_name":"Bash","tool_input":{"command":"scancel --name myjob"}}'
assert_ctx "scancel --name fires sibling-job reminder" "scancel <jobid>"
run '{"tool_name":"Bash","tool_input":{"command":"kill $(jobs -p)"}}'
assert_ctx "kill \$(jobs -p) fires empty-jobtable reminder" "no-ops and leaks"
run '{"tool_name":"Bash","tool_input":{"command":"sleep 30 && echo done"}}'
assert_ctx "foreground sleep fires Monitor reminder" "until-loop"

echo '=== in-code pipe-triggered footguns (cannot live in the |-conf) ==='
run '{"tool_name":"Bash","tool_input":{"command":"python train.py | tail -20"}}'
assert_ctx "python | tail fires block-buffer reminder" "python -u"
run '{"tool_name":"Bash","tool_input":{"command":"ml Python | tail"}}'
assert_ctx "ml | tail fires eval-loss reminder" "forks a subshell"

echo '=== dedup: same (window, tag) fires at most once ==='
run '{"tool_name":"Bash","tool_input":{"command":"pgrep -f other-marker"}}'
assert_silent "second pkill-family call is silent (already seen)"

echo '=== pass-through: benign and non-Bash calls ==='
run '{"tool_name":"Bash","tool_input":{"command":"ls -la && grep foo bar"}}'
assert_silent "benign command injects nothing"
run '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
assert_silent "non-Bash tool is skipped"

echo '=== self-matching process-table lookups (your-org/nexus-code#861) ==='
# Every case below gets a FRESH window. The hook dedups per (window, tag),
# so a "silent" assertion in an exhausted window would pass because the tag
# had ALREADY fired — not because no row matched. That is a vacuous control
# of exactly the shape this suite exists to catch, so the negatives must
# start clean or they prove nothing.
win() { export NEXUS_WORKER_WINDOW="fg-$1"; }

# -- the flag-order gap: `-f` after another flag used to slip through --
win pk-uf
run '{"tool_name":"Bash","tool_input":{"command":"pkill -u operator -f my-marker"}}'
assert_ctx "pkill -u USER -f (flag before -f) still fires self-kill" "self-kill"
win pg-uf
run '{"tool_name":"Bash","tool_input":{"command":"pgrep -u $USER -f some-job.sh --run"}}'
assert_ctx "pgrep -u USER -f (flag before -f) fires the family reminder" "rides claude's argv"
win pg-full
run '{"tool_name":"Bash","tool_input":{"command":"pgrep --full some-job"}}'
assert_ctx "pgrep --full (long option) fires the family reminder" "rides claude's argv"

# -- the WAIT shape must win over the KILL shape (row order is load-bearing) --
win wait-until
run '{"tool_name":"Bash","tool_input":{"command":"until ! pgrep -u operator -f my-job; do sleep 15; done"}}'
assert_ctx "until-! pgrep wait-loop names the HANG, not a kill" "cannot exit"
assert_ctx_absent "…and does NOT deliver the self-kill message instead" "self-kill"
win wait-while
run '{"tool_name":"Bash","tool_input":{"command":"while pgrep -f my-job >/dev/null; do sleep 5; done"}}'
assert_ctx "while-pgrep wait-loop names the HANG" "cannot exit"

# -- ps | grep: same mechanism, pipe trigger, so matched in-code --
win ps-grep
run '{"tool_name":"Bash","tool_input":{"command":"ps aux | grep my-job"}}'
assert_ctx "ps … | grep fires the phantom-self-match reminder" "always matches ITSELF"

# -- negatives: the SAFE forms, and the remedies this guard prescribes --
# A guard that warns about its own recommended fix trains the reader to
# ignore it, so the remedies are pinned as controls, not assumed.
win safe-x
run '{"tool_name":"Bash","tool_input":{"command":"pgrep -x sleep"}}'
assert_silent "pgrep -x NAME (no -f) is the safe form and stays silent"
win safe-kill0
run '{"tool_name":"Bash","tool_input":{"command":"while kill -0 \"$pid\" 2>/dev/null; do sleep 15; done"}}'
assert_silent "the prescribed pid-based wait does NOT warn"
win safe-sentinel
run '{"tool_name":"Bash","tool_input":{"command":"until [ -f \"$SENTINEL\" ]; do sleep 30; done"}}'
assert_silent "the floor's sentinel Monitor loop does NOT warn"

# `pgrep -P` IS THE FORM THIS REPO BLESSES, and the wait rows used to flag it.
# `lint-no-mass-kill.sh`: "PID-scoped `pkill -P` / `pgrep -P` are deliberately
# allowed"; there are 26 call sites in the tree. The self-match the message
# describes needs FULL-ARGV matching, which `-P` is not, so a warning here is
# simply wrong — and it is the shape a reader meets while writing the fix.
#
# The MULTI-LINE form is the one that mattered: `[^;]` blocks the usual
# `while read …; do` because of the semicolon, but the semicolon-free
# newline spelling sailed through and fired procmatch-wait.
win safe-pgrep-P-semicolon
run '{"tool_name":"Bash","tool_input":{"command":"while read -r c; do echo \"$c\"; done < <(pgrep -P $$)"}}'
assert_silent "pgrep -P in a while-read (semicolon form) stays silent"

win safe-pgrep-P-newline
run '{"tool_name":"Bash","tool_input":{"command":"while read -r c\ndo\n  echo \"$c\"\ndone < <(pgrep -P $$)"}}'
assert_silent "pgrep -P in a MULTI-LINE while-read stays silent (the false positive)"

# The other two non-argv matchers, for the same reason.
win safe-wait-x
run '{"tool_name":"Bash","tool_input":{"command":"until ! pgrep -x mydaemon; do sleep 5; done"}}'
assert_silent "a wait-loop on pgrep -x (comm match) cannot self-match, so it stays silent"

export NEXUS_WORKER_WINDOW="footgun-test"
echo '=== output is valid JSON on a match ==='
# Every conf tag has already fired for window "footgun-test" above, so the
# per-(window,tag) dedup would (correctly) silence a repeat here — leaving
# nothing to validate. Switch to a fresh window to exercise a clean
# first-fire. The `-n "$OUT"` guard makes the assertion reject an empty
# capture regardless of jq version: jq 1.5 exits 0 on empty stdin (masking
# a silenced fire), newer jq errors — so empty must fail explicitly.
export NEXUS_WORKER_WINDOW="footgun-json-check"
run '{"tool_name":"Bash","tool_input":{"command":"scancel --partition foo"}}'
if [[ -n "$OUT" ]] && printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
    printf '  PASS: additionalContext is valid hookSpecificOutput JSON\n'; PASS=$((PASS+1))
else
    printf '  FAIL: additionalContext JSON malformed: %q\n' "$OUT" >&2; FAIL=$((FAIL+1))
fi

echo '=== force-push boundary rows (your-org/nexus-code#835) ==='
# The floor carries only the SHARED-vs-OWN boundary; the checkable
# precondition and the merge-ref rationale are delivered HERE, at the push.
# Three properties, each of which failed a plausible alternative design:
#
#   (a) ROW ORDER. The guard takes the FIRST matching row, and the generic
#       `git-push` row matches every force-push too. The force-push rows must
#       therefore precede it in the conf, or the worker doing the rebase the
#       merge gate REQUIRES gets the generic reminder and never sees the
#       boundary. Asserted by tag, not by mere presence of some message.
#   (b) NO ALTERNATION. The conf is `|`-delimited, so the regex field cannot
#       hold a bare `|`. THREE rows share one tag: `--force*`, `-[a-zA-Z]*f`
#       (order-insensitive, so clustered `-uf` fires — it is a real forced
#       update and used to miss), and `[[:space:]]\+` for the +refspec forms.
#       The tempting single form `[[:space:]]-[-]*f` also fires on
#       `--follow-tags`; that false positive is pinned below.
#   (c) THE PIPE SURVIVES. The precondition IS a pipeline. It lives in the
#       MESSAGE, which is `read`'s LAST field and therefore absorbs embedded
#       delimiters intact. If anyone re-splits that field, the worker loses
#       the command mid-sentence.
#   (d) THE EXCLUSION CLASS SEES PIPES. `[^;&\p]` means "still in the same
#       command"; `\p` is the hook's literal-`|` escape. Without it, the
#       SECOND command's `-f` is read as git's and (first-match-wins) the
#       worker LOSES the cwd-pinning reminder. The example after the pipe must
#       contain no letter `p` — see the note at that assertion; with a `grep`
#       there the check cannot fail and pins nothing.
export NEXUS_WORKER_WINDOW="footgun-fp-1"
run '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin operator/835"}}'
assert_ctx "--force-with-lease fires the force-push row, not the generic one" "[force-push]"
assert_ctx "  …and names the SHARED-branch boundary" "NEVER force-push a SHARED branch"
assert_ctx "  …and licenses the rebase the merge gate requires" "is EXPECTED"
assert_ctx "  …and points at the FAIL-CLOSED checker, not a two-step recipe" \
           "monitor/force-push-check.sh <your git push args>"
assert_ctx "  …and names all four exit codes incl. REFUSED-is-not-a-clearance" \
           "2=REFUSED (could not determine — NOT a clearance)"
assert_ctx "  …and warns the hand-rolled form is silently vacuous" \
           "FOUR measured false-clearance modes"
assert_ctx "  …and refuses the AUTHOR check as a false clearance" \
           "an AUTHOR check cannot see a sibling"
assert_ctx "  …and warns that comparing HEAD is a FALSE SAFE (#835 R1)" \
           "git push --dry-run --porcelain --force"
# NOT "prefers --force-with-lease" — it was measured NOT to backstop this
# case at all (its lease is satisfied by the fetch the rebase requires), so
# the message must say so and hand over the PINNED form instead.
assert_ctx "  …and says --force-with-lease does NOT backstop it" \
           "lease is satisfied by the very fetch a rebase requires"
assert_ctx "  …and gives the pinned lease form that does bite" \
           "--force-with-lease=<branch>:<sha-you-saw-before-fetching>"

export NEXUS_WORKER_WINDOW="footgun-fp-2"
run '{"tool_name":"Bash","tool_input":{"command":"git push -f"}}'
assert_ctx "short -f fires the force-push row too (second row, same tag)" "[force-push]"

export NEXUS_WORKER_WINDOW="footgun-fp-3"
run '{"tool_name":"Bash","tool_input":{"command":"git -C /clone push --force origin br"}}'
assert_ctx "git -C <clone> push --force still fires it" "[force-push]"

# Negative half: the boundary must not swallow ordinary pushes, or the
# force-push reminder becomes noise and the generic cwd-leak rule is lost.
# The +refspec forms. `git push origin +dev` IS the forbidden act — a forced
# update of a shared branch — and drew no force-push warning at all before
# these rows existed. Verified against real forced updates, not read off the
# man page (#835 skeptic, Finding 2).
export NEXUS_WORKER_WINDOW="footgun-fp-plus1"
run '{"tool_name":"Bash","tool_input":{"command":"git push origin +dev"}}'
assert_ctx "+refspec (bare branch) fires the force-push row" "[force-push]"
export NEXUS_WORKER_WINDOW="footgun-fp-plus2"
run '{"tool_name":"Bash","tool_input":{"command":"git push origin +HEAD:main"}}'
assert_ctx "+HEAD:main fires the force-push row" "[force-push]"
export NEXUS_WORKER_WINDOW="footgun-fp-plus3"
run '{"tool_name":"Bash","tool_input":{"command":"git push origin +refs/heads/dev"}}'
assert_ctx "+refs/heads/… fires the force-push row" "[force-push]"

# Clustered short flags, BOTH orders. `-uf` missed under the old `-f` regex
# because it required `f` immediately after the dash; git accepts the cluster
# and it is a real forced update.
export NEXUS_WORKER_WINDOW="footgun-fp-clu1"
run '{"tool_name":"Bash","tool_input":{"command":"git push -uf origin main"}}'
assert_ctx "clustered -uf fires (order-insensitive short flags)" "[force-push]"
export NEXUS_WORKER_WINDOW="footgun-fp-clu2"
run '{"tool_name":"Bash","tool_input":{"command":"git push -fu origin main"}}'
assert_ctx "clustered -fu fires too" "[force-push]"

# The exclusion class must see a PIPE as a command boundary, or the SECOND
# command's -f is read as git's. The worker would also LOSE the generic cwd
# reminder, since first-match-wins.
#
# THE COMMAND AFTER THE PIPE MUST CONTAIN NO LETTER `p`. This assertion is the
# only executable check on `\p`, and with the wrong example it is VACUOUS:
# unsubstituted, `[^;&\p]` is a bracket class excluding `;`, `&`, `\` and the
# LETTER `p`, so a `grep` after the pipe blocks the match on its own `p` and the
# test passes whether or not `\p` works at all. Measured:
#
#   … | grep  -f …   unsubstituted: no match  -> assertion cannot fail  [VACUOUS]
#   … | xargs -f …   unsubstituted: MATCHES   -> assertion fails        [SOUND]
#
# `xargs` has no `p`, so only the real `|` exclusion can suppress it. Verified
# by deleting the `\p` substitution from the hook: this suite goes 31/1 with
# `xargs`, and stays 32/0 with `grep`. Do not "simplify" this back to grep.
export NEXUS_WORKER_WINDOW="footgun-fp-pipe"
run '{"tool_name":"Bash","tool_input":{"command":"git push origin main | xargs -f /tmp/pats"}}'
assert_ctx "a pipe ends the command: the NEXT command's -f is not git's" "[git-push]"

export NEXUS_WORKER_WINDOW="footgun-fp-4"
run '{"tool_name":"Bash","tool_input":{"command":"git push origin dev"}}'
assert_ctx "an ordinary push still gets the generic cwd-leak row" "[git-push]"

export NEXUS_WORKER_WINDOW="footgun-fp-5"
run '{"tool_name":"Bash","tool_input":{"command":"git push --follow-tags"}}'
assert_ctx "--follow-tags is NOT read as a force-push (the -[-]*f trap)" "[git-push]"

export NEXUS_WORKER_WINDOW="footgun-fp-6"
run '{"tool_name":"Bash","tool_input":{"command":"git push --set-upstream origin foo"}}'
assert_ctx "--set-upstream is NOT read as a force-push" "[git-push]"

# The two tags dedup INDEPENDENTLY: a worker who pushed normally earlier in
# the session must still receive the boundary when it later force-pushes.
# A shared tag would silently swallow exactly the reminder that matters.
export NEXUS_WORKER_WINDOW="footgun-fp-7"
run '{"tool_name":"Bash","tool_input":{"command":"git push origin dev"}}'
assert_ctx "session's first push: generic row" "[git-push]"
run '{"tool_name":"Bash","tool_input":{"command":"git push -f origin mine"}}'
assert_ctx "later force-push STILL fires despite the generic row having fired" "[force-push]"
run '{"tool_name":"Bash","tool_input":{"command":"git push -f origin mine"}}'
assert_silent "…and dedups on the second force-push"


echo '=== kill-list-denylist rows, and the ROW ORDER they depend on (#851) ==='
# THE ROWS HAD NO COVERAGE AT ALL when they were written, which is how the
# shadowing below survived a green run on both sides of a merge.
#
# ORDER IS LOAD-BEARING FOR FOUR TAGS NOW, not two. The hook takes the FIRST
# matching row, and these shapes overlap pairwise:
#
#   `kill $(pgrep -u "$USER" -f X)`  matches kill-list-denylist AND pkill-self
#   `until ! pgrep -f X`             matches procmatch-wait      AND pkill-self
#   `git push --force`               matches force-push          AND git-push
#
# So the conf order must be procmatch-wait, kill-list-denylist, pkill-self,
# … force-push, git-push. Every assertion below pins a TAG, not the mere
# presence of some message: a wrong-but-present reminder is the failure mode
# (it teaches the reader the tag is inapplicable and to ignore it).
#
# Measured before this fix: with kill-list-denylist BELOW pkill-self, the
# pgrep row was unreachable for any pgrep carrying -f — the only form its own
# message is about — so the one reminder naming `proc-kill-authorized --filter`
# never fired, and BOTH suites stayed green.
win kl-ps-pipeline
run '{"tool_name":"Bash","tool_input":{"command":"kill $(ps -eo pid=,args= | awk \"/run-tests/ {print $1}\")"}}'
assert_ctx "a kill list built from ps names the ownership helper" "[kill-list-denylist]"

win kl-pgrep-scoped
run '{"tool_name":"Bash","tool_input":{"command":"kill $(pgrep -u \"$USER\" -f run-tests.sh)"}}'
assert_ctx "…and so does one built from a SCOPED pgrep -f (the shadowed case)" "[kill-list-denylist]"

win kl-pgrep-bare
run '{"tool_name":"Bash","tool_input":{"command":"kill $(pgrep -f run-tests.sh)"}}'
assert_ctx "…and from a bare pgrep -f" "[kill-list-denylist]"

win kl-order-wait
run '{"tool_name":"Bash","tool_input":{"command":"until ! pgrep -u $USER -f myjob; do sleep 15; done"}}'
assert_ctx "a WAIT loop still outranks both kill rows" "[procmatch-wait]"

win kl-order-pkill
run '{"tool_name":"Bash","tool_input":{"command":"pkill -u \"$USER\" -f myjob"}}'
assert_ctx "a plain pkill -f — not a list — still gets pkill-self" "[pkill-self]"

win kl-order-forcepush
run '{"tool_name":"Bash","tool_input":{"command":"git push --force origin mine"}}'
assert_ctx "force-push still outranks the generic git-push row" "[force-push]"

# ---- assertion-count guard ------------------------------------------------
# The summary reports assertions that RAN. One that never ran is invisible to
# it: a typo'd helper name is `command not found`, tallied by nothing, and the
# footer still says ALL TESTS PASSED with a quieter number. This suite has no
# conditional cases, so the count is exact. Bump it deliberately when adding a
# case; a DROP means a case stopped running.
_EXPECTED_ASSERTIONS=54
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; PASS=$((PASS+1))
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    FAIL=$((FAIL+1))
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
