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
    if [[ -z "${2:-}" ]]; then
        printf '  FAIL: %s — EMPTY needle: `*""*` matches any string, so this assertion\n' "$1" >&2
        printf '         could only have passed VACUOUSLY (your-org/nexus-code#1110).\n' >&2
        printf '         Fix the CALLER, not the haystack: its expected value came back\n' >&2
        printf '         empty; check the rc of whatever produced it.\n' >&2
        FAIL=$((FAIL+1))
        return
    fi
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
# win <suffix> — switch to a FRESH window so per-(window,tag) dedup cannot make
# a negative assertion vacuous. Defined here, with the other helpers, because
# cases above the old definition site now use it: an undefined helper is
# `command not found` at rc 127, which this suite tallies nowhere.
win() { export NEXUS_WORKER_WINDOW="fg-$1"; }

# assert_ctx_first <desc> <tag> — the FIRST rule in a multi-rule payload is
# <tag>. Under your-org/nexus-code#1057 every matching rule is delivered, so
# "the other message is absent" is no longer the claim row order makes;
# "this message comes FIRST" is, and it is the one worth pinning. An `absent`
# assertion here would now be testing the pre-emption bug, not the ordering.
assert_ctx_first() {
    local first
    first=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null \
            | grep -oE 'bash-footgun-guard \[[a-z-]+\]' | head -1)
    if [[ $RC -eq 0 && "$first" == "bash-footgun-guard [$2]" ]]; then
        printf '  PASS: %s\n' "$1"; PASS=$((PASS+1))
    else
        printf '  FAIL: %s (rc=%s first=%q wanted=%q)\n' "$1" "$RC" "$first" "$2" >&2; FAIL=$((FAIL+1))
    fi
}
# assert_ctx_tags <desc> <n> — exactly <n> rules were delivered.
assert_ctx_tags() {
    local n
    n=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null \
        | grep -cE '^bash-footgun-guard \[[a-z-]+\]:')
    if [[ $RC -eq 0 && "$n" == "$2" ]]; then
        printf '  PASS: %s\n' "$1"; PASS=$((PASS+1))
    else
        printf '  FAIL: %s (rc=%s delivered=%s wanted=%s)\n' "$1" "$RC" "$n" "$2" >&2; FAIL=$((FAIL+1))
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
assert_ctx "  …and no longer stops at the SELF match (#1073)" "AND IT DOES NOT STOP AT YOU"
assert_ctx "  …retiring the marker-absent-from-YOUR-prompt advice as insufficient" "NOT sufficient"
run '{"tool_name":"Bash","tool_input":{"command":"cd a && git push origin x"}}'
assert_ctx "git push fires wrong-remote reminder" "git -C <clone> push"
run '{"tool_name":"Bash","tool_input":{"command":"scancel --name myjob"}}'
assert_ctx "scancel --name fires sibling-job reminder" "scancel <jobid>"
run '{"tool_name":"Bash","tool_input":{"command":"kill $(jobs -p)"}}'
assert_ctx "kill \$(jobs -p) fires empty-jobtable reminder" "no-ops and leaks"
run '{"tool_name":"Bash","tool_input":{"command":"sleep 30 && echo done"}}'
# The label said "Monitor" while the assertion checked for "until-loop" — the
# very shape your-org/nexus-code#1236 demoted. Asserting the presence of the
# counterexample is a weak check that would pass on the defect, so it is
# replaced by assertions on what the row must now LEAD with. The `Monitor`
# half is kept because it is load-bearing and separate: a 1800s wait budget
# outlives any foreground tool call, so WHERE the wait runs still matters.
assert_ctx "foreground sleep fires the wait-shape reminder"      "proc-exists-authorized"
assert_ctx "  …and says where the wait may live"                "Monitor"
# THE #1236 FIX, ASSERTED. The row's lead must carry a DEADLINE and an
# EXIT-STATUS consultation — the two properties its own conclusion argued for
# and its old lead example omitted.
assert_ctx "  …and the prescribed shape carries a DEADLINE"     "--timeout"
assert_ctx "  …and a RETAINED exit status to consult"           "--status-line"
assert_ctx "  …and names TIMEOUT as a distinct rc, not an absence" "4 TIMEOUT"
# And the bare until-loop must now appear as a NAMED COUNTEREXAMPLE rather
# than as the prescription — with its witness, because a 28-hour wait on a
# sentinel that can never appear is what makes the point unarguable.
assert_ctx "  …demotes the bare until-loop explicitly"          "IS NOT ONE"
assert_ctx "  …with the never-appearing-sentinel witness"       "NEVER APPEAR"
assert_ctx "  …and names the verdict no file predicate can express" "\`died\`"
# This row HANDS OUT the wait shape, so it must also name what makes that
# shape unwaitable — and post-#1073 that is the sibling half, not just self.
assert_ctx "  …and the row that hands out the wait shape names the sibling half" "SIBLING agent"
assert_ctx "  …and points at the loop-owning tool" "proc-exists-authorized"

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
assert_silent "non-command-carrying tool is skipped"

echo '=== pipe-status: the tail-pipeline family third member (#1046) ==='
# THE FIVE INSTANCES ARE REAL. All were produced in ONE day by ONE careful
# agent, on a task whose entire subject was silence mistaken for evidence — and
# the fifth was written INSIDE a retry loop built to defend against this exact
# trap. Knowing the failure mode did not prevent it, which is the argument for
# enrolment rather than exhortation.
win ps-or
run '{"tool_name":"Bash","tool_input":{"command":"./monitor/window-close.sh 17 | tail -5 || tmux kill-window -t 17 && echo \"closed 17\""}}'
assert_ctx "MANUFACTURED success (|| never ran) fires pipe-status" "[pipe-status]"
assert_ctx "  …and names the manufacturing direction as the severe one" "MANUFACTURING a success is not"

win ps-qmark
run '{"tool_name":"Bash","tool_input":{"command":"bash -c \"exit 1\" | tail -8; echo \"rc=$?\""}}'
assert_ctx "MASKED failure read via \$? fires pipe-status" "[pipe-status]"

win ps-push
run '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/c push origin dev | tail -2; rc=$?"}}'
assert_ctx "git push | tail -2 with rc=\$? fires (instance 5)" "[pipe-status]"

win ps-nextline
run '{"tool_name":"Bash","tool_input":{"command":"skeptic-channel.sh await w | tail -15\nrc=$?\necho $rc"}}'
assert_ctx "\$? on the FOLLOWING line still fires (instance 1)" "[pipe-status]"

win ps-if
run '{"tool_name":"Bash","tool_input":{"command":"if ./probe.sh | wc -l; then echo bad; fi"}}'
assert_ctx "a swallowing pipeline in an if-condition fires" "[pipe-status]"

win ps-and
run '{"tool_name":"Bash","tool_input":{"command":"ng guards-for-diff | tail -20 && echo SAFE-TO-PUSH"}}'
assert_ctx "&& after a swallowing pipeline fires (instance 3)" "[pipe-status]"

win ps-wc
run '{"tool_name":"Bash","tool_input":{"command":"./enumerate.sh | wc -l || echo FALLBACK"}}'
assert_ctx "wc as the swallowing terminator fires" "[pipe-status]"

echo '=== pipe-status MUST NOT FIRE on the legitimate population (#1046) ==='
# This half is load-bearing. A bare `| tail` is extremely common and almost
# always harmless; an arm that fired on every one would be tuned out and would
# DEGRADE the two pipe arms above that currently work. Each case below is a
# shape that appears constantly in this repo and must stay silent.
win ps-bare1
run '{"tool_name":"Bash","tool_input":{"command":"git log --oneline | tail -20"}}'
assert_silent "bare | tail with no status consumption stays silent"
win ps-bare2
run '{"tool_name":"Bash","tool_input":{"command":"cat report.md | head -40"}}'
assert_silent "bare | head stays silent"
win ps-bare3
run '{"tool_name":"Bash","tool_input":{"command":"git ls-files | wc -l"}}'
assert_silent "bare | wc -l (a count, not a test) stays silent"
win ps-redir
run '{"tool_name":"Bash","tool_input":{"command":"./run.sh | tail -100 > out.txt"}}'
assert_silent "| tail redirected to a file stays silent"
win ps-firststage
run '{"tool_name":"Bash","tool_input":{"command":"tail -f app.log | grep --line-buffered ERROR || true"}}'
assert_silent "tail as the FIRST stage (grep last, not -c) stays silent"
win ps-midpipe
run '{"tool_name":"Bash","tool_input":{"command":"./gen.sh | head -50 | sort -u > x"}}'
assert_silent "head piped ONWARD (not the last stage) stays silent"
win ps-unrelated
run '{"tool_name":"Bash","tool_input":{"command":"./build.sh; rc=$?; echo \"build rc=$rc\""}}'
assert_silent "an rc check with NO swallowing pipeline stays silent"
# `grep -c` IS NOT A SWALLOWER and must never key this arm. It exits 1 on zero
# matches (measured), so `| grep -c X || true` is the CORRECT absorption of
# grep's own zero-count status — the commonest shape of all here — and not the
# #1046 defect. #1046's own list included `grep -c`; that part of the issue is
# wrong, and keying on it would buy false alarms for zero real coverage, since
# all five field instances terminate in `tail`.
#
# THE SIZE OF THAT NOISE, with the command and the ref beside it, because a
# count is a property of a tree:
#
#   git grep -hE "[|][[:space:]]*grep[[:space:]]+-[A-Za-z]*c[A-Za-z]*[^;|&]*([|][|]|&&)" \
#       1475509 -- '*.sh'          # -> 45 sites
#   …same with "[|][|][[:space:]]*true" in place of the trailing group  # -> 40
#
# AND THE FIGURE IS SELF-REFERENTIAL, which is the part worth knowing before you
# re-run it. At `2d32449`/`100cf13` it was 39/34; from `00524c0` it is 45/40. The
# +6 is this change's own text — one line in the guard quoting the idiom as an
# example, and FIVE IN THIS FILE (the comment above plus the cases below).
# Writing the justification moved the number it cites. So a larger figure on a
# later tree is expected and does not mean the comment rotted; re-derive at the
# ref you care about. The decision is unaffected — 45/40 argues it more strongly.
#
# And the loop continues: this very note quotes the idiom again, so the figure at
# the merge of the change that added it is 46/41. 45/40 is quoted because
# `1475509` is a ref that EXISTS and can be re-run — a count of a tree that does
# not exist yet is not checkable, which is the rule being applied. Expect +1 per
# future mention rather than reading growth as rot.
win ps-grepc1
run '{"tool_name":"Bash","tool_input":{"command":"printf \"%s\" \"$out\" | grep -c \":\" || true"}}'
assert_silent "| grep -c … || true (grep's OWN zero-match rc) stays silent"
win ps-grepc2
run '{"tool_name":"Bash","tool_input":{"command":"n=$(printf \"%s\\n\" \"$pop\" | grep -c . || true)"}}'
assert_silent "a counted capture via grep -c stays silent"
win ps-grepc3
run '{"tool_name":"Bash","tool_input":{"command":"if ./probe.sh | grep -c ERROR; then echo found; fi"}}'
assert_silent "grep -c in an if-condition is a MATCH TEST, not a swallowed status"
# WORD BOUNDARY. Without a trailing boundary the swallower names match as
# SUBSTRINGS, so any command whose name merely BEGINS with one fires. Found by an
# independent review pass, and measured firing before the fix.
win ps-wordb1
run '{"tool_name":"Bash","tool_input":{"command":"mycmd | headers.py --check && echo ok"}}'
assert_silent 'a command NAMED headers.py is not head (word boundary)'
win ps-wordb2
run '{"tool_name":"Bash","tool_input":{"command":"mycmd | tailscale status && echo ok"}}'
assert_silent 'a command NAMED tailscale is not tail (word boundary)'
win ps-wordb3
run '{"tool_name":"Bash","tool_input":{"command":"mycmd | wcgrep x && echo ok"}}'
assert_silent 'a command NAMED wcgrep is not wc (word boundary)'
# A `case` alternation carries a bare `|` before a swallower word.
win ps-case
run '{"tool_name":"Bash","tool_input":{"command":"case \"$m\" in GET|get|HEAD|head) : ;; *) die ;; esac"}}'
assert_silent "a case alternation naming head is not a pipeline"

echo '=== pipe-status MUST NOT punish the remedy it prescribes (#904 leg G) ==='
# THE ARM'S OWN MESSAGE names `set -o pipefail` and the capture-before-piping
# form as the fixes. Firing on them is `#1059` a second time: there the message
# told a complying worker to do what it had already done; here it tells a
# complying worker it did the thing wrong. Measured over 136,424 Bash tool-call
# command strings from 1,367 transcripts under `~/.claude/projects/**/*.jsonl`
# (2026-07-31 .. 2026-09-02): of 7,829 arm matches, 1,042 carry a real `set -o
# pipefail`, 117 more read a `${PIPESTATUS[n]}` array, and 1,338 read `$?` to
# the LEFT of the swallowing pipe. 31.9% of every fire.
win ps-pipefail
run '{"tool_name":"Bash","tool_input":{"command":"set -o pipefail; monitor/ng report-check r.md 2>&1 | tail -5; echo \"rc=$?\""}}'
assert_silent "an explicit set -o pipefail disarms the arm"
win ps-pipestatus-bash
run '{"tool_name":"Bash","tool_input":{"command":"bash gate.sh 2>&1 | tail -6 && echo \"rc=${PIPESTATUS[0]}\""}}'
assert_silent "a \${PIPESTATUS[n]} read disarms the arm"
win ps-pipestatus-zsh
run '{"tool_name":"Bash","tool_input":{"command":"bash gate.sh 2>&1 | tail -6 && echo \"rc=${pipestatus[0]}\""}}'
assert_silent "the zsh \${pipestatus[n]} spelling disarms it too"
win ps-capture
run '{"tool_name":"Bash","tool_input":{"command":"out=$(monitor/ng send sk --file d.md 2>&1); echo \"rc=$?\"; echo \"$out\" | tail -2"}}'
assert_silent "a \$? read to the LEFT of the pipe is the CAPTURE IDIOM, not the defect"

echo '=== …and the disarm must not become a silent false NEGATIVE (#904 leg G) ==='
# NEGATIVE CONTROL FOR THE DISARM ITSELF, and it is the one that caught a real
# error: a first cut keyed on the bare words `pipefail|PIPESTATUS` anywhere in
# the command disarmed FIVE genuine defects in an 80-command sample, every one
# merely NAMING a file. A disarm keyed on a substring of a filename is a silent
# false negative inside a guard — strictly worse than the noise it removes.
win ps-still-fires
run '{"tool_name":"Bash","tool_input":{"command":"monitor/ng report-check r.md 2>&1 | tail -5; echo \"check rc=$?\""}}'
assert_ctx "the plain defect (\$? AFTER the pipe) still fires" "[pipe-status]"
win ps-filename-not-a-disarm
run '{"tool_name":"Bash","tool_input":{"command":"bash monitor/watcher/test-early-exit-pipefail-axis.sh 2>&1 | tail -3; echo \"rc=$?\""}}'
assert_ctx "a FILENAME containing pipefail does NOT disarm the arm" "[pipe-status]"

echo '=== command-carrying tools beyond Bash (your-org/nexus-code#927) ==='
# THE GAP THIS CLOSES: the guard was registered on `Bash` alone, but `Monitor`
# runs .tool_input.command in the same shell environment, so every footgun here
# was reachable through it unguarded — and the WAIT shape most of all, because
# Monitor is the tool this very conf's `foreground-sleep` row sends workers to.
# Measured before the fix: the SAME command warned via Bash and was silent via
# Monitor. PreToolUse does fire for Monitor (tool_name=Monitor), verified by
# driving a real claude with a Monitor-matched hook — so this is a reachable
# arm, not an aspirational one.
win monitor-wait
run '{"tool_name":"Monitor","tool_input":{"command":"until ! pgrep -u $USER -f my-job; do sleep 10; done"}}'
assert_ctx "a Monitor wait-loop gets the same procmatch-wait warning as Bash" "[procmatch-wait]"
win monitor-push
run '{"tool_name":"Monitor","tool_input":{"command":"git push --force origin dev"}}'
assert_ctx "a Monitor command is guarded for non-wait footguns too" "[force-push]"
win monitor-benign
run '{"tool_name":"Monitor","tool_input":{"command":"tail -f app.log | grep --line-buffered ERROR"}}'
assert_silent "a legitimate Monitor tail-loop stays clean"
win monitor-ws
run '{"tool_name":"Monitor","tool_input":{"ws":{"url":"wss://x/y"}}}'
assert_silent "a Monitor ws watch (no .command) is passed through, not crashed"

echo '=== an already-seen tag skips its ROW, it does not end the guard (#927) ==='
# THE MUTING DEFECT: `already_seen && exit 0` left the WHOLE hook, so the first
# already-seen match disarmed every later rule for that command — including the
# three in-code checks, which sit after the conf loop and were the most exposed.
# 207 of 421 live windows carried >=2 sentinels, i.e. were already in that
# regime. Each leg below uses a fresh window so the control cannot be vacuous.
win mute-conf
run '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
assert_ctx "leg 1: git-push fires and is now a SEEN tag for this window" "[git-push]"
run '{"tool_name":"Bash","tool_input":{"command":"git push origin main && ps aux | grep watcher"}}'
assert_ctx "leg 2: the seen git-push row no longer mutes the in-code ps|grep rule" \
           "[procmatch-self]"
win mute-wait
run '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
assert_ctx "leg 1: git-push seen" "[git-push]"
run '{"tool_name":"Bash","tool_input":{"command":"git push origin main\nuntil ! pgrep -u $USER -f my-job; do sleep 10; done"}}'
assert_ctx "leg 2: a seen tag no longer hides the WEDGE rule behind it" "[procmatch-wait]"

echo '=== …but the noise budget is unchanged: at most ONE reminder per command ==='
# The fix must not turn one command into a wall of reminders — that is how a
# guard gets switched off by whoever is under time pressure. Exactly one
# additionalContext object is emitted even when three rules match.
win one-shot
run '{"tool_name":"Bash","tool_input":{"command":"git push --force origin dev && pkill -f x && ps aux | grep y"}}'
_n=$(printf '%s' "$OUT" | grep -c 'additionalContext')
if [[ "$_n" -eq 1 ]]; then
    printf '  PASS: three matching rules still deliver exactly ONE reminder\n'; PASS=$((PASS+1))
else
    printf '  FAIL: expected 1 reminder, got %s: %q\n' "$_n" "$OUT" >&2; FAIL=$((FAIL+1))
fi
# Conf order is the priority order, and pkill-self sits ABOVE force-push, so
# the kill rule is the correct winner here. Asserted by tag so a future row
# insertion that changes the answer reddens this instead of passing quietly.
assert_ctx "  …and it is the FIRST matching row in conf order" "[pkill-self]"

echo '=== a `block` row outranks an earlier `warn` row, not just file order ==='
# Delivering severity purely by position means a severe rule added late in the
# conf is pre-empted by any advisory above it. The shipped conf is warn-only,
# so this is exercised against a purpose-built two-row conf: a warn that
# matches FIRST, a block that matches SECOND. Correct answer is the block, at
# rc 2 (PreToolUse blocking error) with the message on stderr.
_bconf=$(mktemp)
printf 'aaa-warn|warn|WARNTRIGGER|advisory row\nzzz-block|block|BLOCKTRIGGER|severe row\n' > "$_bconf"
win block-priority
_bout=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"WARNTRIGGER and BLOCKTRIGGER"}}' \
    | NEXUS_FOOTGUN_PATTERNS="$_bconf" bash "$HOOK" 2>&1); _brc=$?
if [[ $_brc -eq 2 && "$_bout" == *"zzz-block"* && "$_bout" != *"aaa-warn"* ]]; then
    printf '  PASS: the later block pre-empts the earlier warn (rc=2)\n'; PASS=$((PASS+1))
else
    printf '  FAIL: block priority (rc=%s out=%q)\n' "$_brc" "$_bout" >&2; FAIL=$((FAIL+1))
fi
rm -f "$_bconf"

echo '=== self-matching process-table lookups (your-org/nexus-code#861) ==='
# Every case below gets a FRESH window. The hook dedups per (window, tag),
# so a "silent" assertion in an exhausted window would pass because the tag
# had ALREADY fired — not because no row matched. That is a vacuous control
# of exactly the shape this suite exists to catch, so the negatives must
# start clean or they prove nothing. (`win` is defined with the helpers above.)

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
# UNDER MULTI-DELIVERY (your-org/nexus-code#1057) the kill row IS also
# delivered — correctly, since `pgrep -f` really is an argv match — so
# "the other message is absent" is no longer the claim row order makes.
# "the HANG is read FIRST" is, and that is what the ordering buys.
assert_ctx_first "…and the WAIT message is the one read FIRST" "procmatch-wait"
# BOTH families must now name the SIBLING population, not just the self-match
# (your-org/nexus-code#1073). The pre-#1073 text made bracketing look
# sufficient; measured, it closes only the observer's own hit.
assert_ctx "…and the wait message names the sibling population, not just self" "SIBLING agent"
assert_ctx "…and hands over the loop-owning tool" "proc-exists-authorized"
assert_ctx "…and demotes bracketing to the half it actually closes" "THIS ONE AND ONLY THIS ONE"
win wait-while
run '{"tool_name":"Bash","tool_input":{"command":"while pgrep -f my-job >/dev/null; do sleep 5; done"}}'
assert_ctx "while-pgrep wait-loop names the HANG" "cannot exit"

# -- ps | grep: same mechanism, pipe trigger, so matched in-code --
win ps-grep
run '{"tool_name":"Bash","tool_input":{"command":"ps aux | grep my-job"}}'
assert_ctx "ps … | grep fires the phantom-self-match reminder" "The grep's OWN argv holds the pattern"

# -- negatives: the SAFE forms, and the remedies this guard prescribes --
# A guard that warns about its own recommended fix trains the reader to
# ignore it, so the remedies are pinned as controls, not assumed.
win safe-x
run '{"tool_name":"Bash","tool_input":{"command":"pgrep -x sleep"}}'
assert_silent "pgrep -x NAME (no -f) is the safe form and stays silent"
win safe-kill0
run '{"tool_name":"Bash","tool_input":{"command":"while kill -0 \"$pid\" 2>/dev/null; do sleep 15; done"}}'
assert_silent "the prescribed pid-based wait does NOT warn"
# REVERSED BY #1236, ARMED BY #1250 — and this assertion is the reversal.
# It used to read "the floor's sentinel Monitor loop does NOT warn", pinning
# `until [ -f X ]; do sleep 30; done` as a BLESSED REMEDY. `#1236` withdrew
# that: the `foreground-sleep` row's own message, already merged, names this
# exact shape as "PRINTED HERE AS THE ANSWER AND IS NOT ONE". So the suite was
# asserting silence over a shape the conf beside it condemns in words — and
# `#1250` measured the consequence: the corrected guidance reached the agent
# writing a bare `sleep` and never reached the agent writing the loop it is
# about. A test that pins the old position keeps the new arm out.
win warn-sentinel
run '{"tool_name":"Bash","tool_input":{"command":"until [ -f \"$SENTINEL\" ]; do sleep 30; done"}}'
assert_ctx "the unbounded sentinel loop WARNS (#1236 condemned it, #1250 armed it)" \
    "An UNBOUNDED SENTINEL WAIT"

# …AND THE REMEDY IT PRESCRIBES MUST STAY SILENT, or this arm trains the reader
# to ignore it — the same control discipline as the block above.
win safe-sentinel
run '{"tool_name":"Bash","tool_input":{"command":"monitor/proc-exists-authorized --until-gone --token \"$t\" --timeout 1800"}}'
assert_silent "the prescribed bounded wait does NOT warn"

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

# ── your-org/nexus-code#941: the (window,tag) sentinel is KEY-ed ──────────
# The de-dup cache was keyed with the lossy sanitiser, so two windows whose
# names collided shared it and one of them silently lost its warning.
#
# The FIRST version of this block was written with a payload missing
# `tool_name` and a command (`killall`) this conf carries no pattern for. It
# produced silence — and its "potency control" was `assert_silent`, which
# silence satisfies. Every assertion agreed for the wrong reason. Payload
# shape and command are now copied from the cases above, which are known to
# fire, and the control asserts a WARNING first so suppression means something.
echo '=== #941: de-dup sentinel is keyed injectively ==='
_fg941() { printf '{"tool_name":"Bash","tool_input":{"command":"pkill -f my-task-marker"}}'; }
_fg941_count() { ls "$STATE/footgun-seen" 2>/dev/null | grep -c "^$1\." ; }

export NEXUS_WORKER_WINDOW='fg941.dot'
run "$(_fg941)"
assert_ctx "#941 a dotted window gets its warning" "pkill"
export NEXUS_WORKER_WINDOW='fg941_dot'
run "$(_fg941)"
assert_ctx "#941 the window that COLLIDED with it warns too (was silently deduped)" "pkill"
# Scoped to these two keys — the shared STATE already holds sentinels from the
# cases above, so a whole-directory count would measure those instead.
_a=$(_fg941_count 'fg941%2Edot'); _b=$(_fg941_count 'fg941_dot')
if [[ "$_a" == "1" && "$_b" == "1" ]]; then
    printf '  PASS: %s\n' "#941 …and they hold SEPARATE sentinels (fg941%2Edot + fg941_dot)"; PASS=$((PASS+1))
else
    printf '  FAIL: %s (encoded=%s legacy-spelled=%s, want 1 and 1)\n' "#941 separate sentinels" "$_a" "$_b" >&2; FAIL=$((FAIL+1))
fi
# POTENCY: the cache must really suppress a repeat, or the two warnings above
# prove nothing about keying — they would fire even with no cache at all.
run "$(_fg941)"
assert_silent "#941 POTENCY: a repeat for the SAME window is suppressed"

# FAIL-OPEN: with the encoder unreachable the hook must still WARN — never
# block, never fall back to the lossy key; the cache simply disables. Polarity
# is inverted versus every other consumer on purpose: a PreToolUse hook that
# failed closed would block every Bash command in the session.
_iso=$(mktemp -d); mkdir -p "$_iso/monitor/hooks"
cp "$HOOK" "$_iso/monitor/hooks/"; cp "$CONF" "$_iso/monitor/patterns.conf"
_isostate=$(mktemp -d)
export NEXUS_WORKER_WINDOW='fg941-open'
_fgopen() {
    OUT=$(printf '%s' "$(_fg941)" \
          | NEXUS_ROOT="$_iso" NEXUS_STATE_DIR="$_isostate" \
            NEXUS_FOOTGUN_PATTERNS="$_iso/monitor/patterns.conf" \
            bash "$_iso/monitor/hooks/bash-footgun-guard.sh"); RC=$?
}
_fgopen; assert_ctx "#941 encoder unreachable: still WARNS (fail-open)" "pkill"
_fgopen; assert_ctx "#941 …and warns AGAIN — cache disabled, not lossy" "pkill"
if [[ "$(ls "$_isostate/footgun-seen" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]]; then
    printf '  PASS: %s\n' "#941 …and wrote NO sentinel under any key"; PASS=$((PASS+1))
else
    printf '  FAIL: %s\n' "#941 wrote a sentinel without an encoder" >&2; FAIL=$((FAIL+1))
fi
rm -rf "$_iso" "$_isostate"
export NEXUS_WORKER_WINDOW="footgun-test"


echo '=== tmux server lethality (your-org/nexus-code#889) ==='
# THE ONLY UNRECOVERABLE FOOTGUN IN THIS CONF. `bwrap` is PID 1 running tmux
# under --die-with-parent, so when the server goes nothing in-sandbox restores
# it. On 2026-08-09 it went, taking the watcher, all 17 worker windows, the
# services window and the operator's session. THE CAUSE WAS NEVER ATTRIBUTED —
# these rows guard a class, and the assertions below must not imply otherwise.
#
# NOTE ON METHOD: every case here is a STRING handed to the guard. This suite
# never invokes tmux, so it cannot itself endanger the board — the safest
# possible design for testing a rule about ending the tmux server. The premise
# behind the untargeted rows (killing the last window of the last session ends
# the server) was verified once, out of band, on a private -S socket asserted
# unequal to the board's; it is not re-run here.
win tmux-ks
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-server"}}'
assert_ctx "unpinned kill-server fires" "[tmux-kill-server]"
assert_ctx "  …and names the socket pin as the remedy" "env -u TMUX tmux -L"
assert_ctx "  …and says TMUX_TMPDIR alone is not containment" "NOT containment"
assert_ctx "  …and does NOT claim the 08-09 cause is known" "NEVER ATTRIBUTED"
win tmux-kw
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-window"}}'
assert_ctx "untargeted kill-window fires" "[tmux-kill-window]"
assert_ctx "  …and names -t as the remedy" "kill-window -t <session>:<index>"
win tmux-kse
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-session"}}'
assert_ctx "untargeted kill-session fires" "[tmux-kill-session]"
win tmux-kp
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-pane"}}'
assert_ctx "untargeted kill-pane fires" "[tmux-kill-pane]"
win tmux-chain
# ORDER OF THE TWO tmux CALLS IS DELIBERATE. The corpus lint
# (_tmux_kill_scan.awk) splits a line on `;`/`&&` and reads a kill verb
# followed by WHITESPACE inside the resulting fragment as a real
# invocation — so `"command":"tmux kill-window ; …"` in a JSON payload
# trips rule3 even though nothing here ever executes tmux. With the verb
# abutting the closing quote it does not. Same assertion, no pragma burned.
run '{"tool_name":"Bash","tool_input":{"command":"tmux new-window ; tmux kill-window"}}'
assert_ctx "untargeted kill in a CHAIN still fires (the ; ends the command)" "[tmux-kill-window]"
win tmux-cd
run '{"tool_name":"Bash","tool_input":{"command":"cd /tmp && tmux kill-server"}}'
assert_ctx "a kill-server later in an &&-chain still fires" "[tmux-kill-server]"
win tmux-tmpdir
run '{"tool_name":"Bash","tool_input":{"command":"TMUX_TMPDIR=/tmp/x tmux kill-server"}}'
assert_ctx "TMUX_TMPDIR without -L/-S is NOT a pin and still fires" "[tmux-kill-server]"

echo '=== …and BOTH DIRECTIONS: the legitimate forms must stay clean ==='
# A guard that flags correct window management on a 19-window board is
# suppressed by the first person under time pressure — which removes the only
# protection against an UNRECOVERABLE event. These seven are the control set.
win tmux-ok-1
run '{"tool_name":"Bash","tool_input":{"command":"tmux list-windows -F \"#{window_name}\""}}'
assert_silent "list-windows is not a kill"
win tmux-ok-2
run '{"tool_name":"Bash","tool_input":{"command":"alias tkill='\''tmux list-windows'\''"}}'
assert_silent "an alias pointing at a non-kill stays clean"
win tmux-ok-3
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-window -t a:2"}}'
assert_silent "a TARGETED kill-window is correct usage"
win tmux-ok-4
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-window -a -t a:1"}}'
assert_silent "flags BEFORE -t do not hide the target (-a -t)"
win tmux-ok-5
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-window -t a:2 ; tmux new-window -t a"}}'
assert_silent "a targeted kill chained with new-window stays clean"
win tmux-ok-6
run '{"tool_name":"Bash","tool_input":{"command":"tmux display-message -p \"#{socket_path}\""}}'
assert_silent "display-message (the containment probe itself) stays clean"
win tmux-ok-7
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-session -t nonexistent-session"}}'
assert_silent "a targeted kill-session stays clean even if the target is absent"

echo '=== …and a correctly PINNED private test server is the prescribed idiom ==='
# The guard must not fire on the very form its own message prescribes.
win tmux-pin-1
run '{"tool_name":"Bash","tool_input":{"command":"env -u TMUX tmux -L probe kill-server"}}'
assert_silent "-L pinned kill-server is the prescribed test-server teardown"
win tmux-pin-2
run '{"tool_name":"Bash","tool_input":{"command":"tmux -S /tmp/priv.sock kill-server"}}'
assert_silent "-S pinned kill-server stays clean"
win tmux-pin-3
run '{"tool_name":"Bash","tool_input":{"command":"env -u TMUX tmux -L probe kill-session -t t"}}'
assert_silent "pinned AND targeted stays clean"

echo '=== the four verbs dedup INDEPENDENTLY (your-org/nexus-code#951 F2) ==='
# One shared tag would spend the family's single warning on whichever verb fired
# first: a worker warned about kill-server at hour 1 got NOTHING when it later
# ran kill-window in the SAME window. Measured before the fix; pinned here.
win tmux-dedup
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-server"}}'
assert_ctx "kill-server warns first" "[tmux-kill-server]"
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-server"}}'
assert_silent "  …and dedups on a REPEAT of the same verb"
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-window"}}'
assert_ctx "  …but a DIFFERENT verb still warns in the same window" "[tmux-kill-window]"
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-pane"}}'
assert_ctx "  …and so does the third" "[tmux-kill-pane]"
run '{"tool_name":"Bash","tool_input":{"command":"tmux kill-session"}}'
assert_ctx "  …and the fourth" "[tmux-kill-session]"

echo '=== the honesty guard needs its ABSENCE half (your-org/nexus-code#951 F1) ==='
# The presence check ("NEVER ATTRIBUTED") catches DELETION of the disclaimer. It
# cannot catch ADDITION of a fabricated cause — and addition is the likely drift:
# somebody later adding helpful context, not somebody deleting a caveat. A
# message can then assert a specific cause AND that no cause was ever
# established, self-contradicting, with nothing to notice. The 08-09 cause is
# genuinely unattributed, so any causal phrasing in these rows is fabricated.
_causal_hits=$(grep -E '^tmux-[a-z-]+\|' "$CONF" \
    | grep -icE 'caused by|was due to|the cause was|root cause was|because a worker|traced to' || true)
if [[ "$_causal_hits" -eq 0 ]]; then
    printf '  PASS: no tmux row asserts a CAUSE for 08-09 (it was never attributed)\n'; PASS=$((PASS+1))
else
    printf '  FAIL: %s tmux row(s) assert a cause the incident never established\n' "$_causal_hits" >&2; FAIL=$((FAIL+1))
fi
# Non-vacuity: the detector must actually fire on a fabricated phrasing, or the
# check above passes by being blind — #618's shape inside its own remedy.
# The count is CAPTURED and compared, not piped into `grep -q`
# (your-org/nexus-code#622's lint): `grep -q` exits on first match without
# draining, so under pipefail the upstream EPIPE inverts the verdict at the
# moment the match succeeds. Capturing removes the early-exiting reader
# entirely, and reads better besides.
_planted_hits=$(printf 'tmux-x|warn|re|the server died because a worker ran kill-window\n' \
     | grep -icE 'caused by|was due to|the cause was|root cause was|because a worker|traced to')
if [ "$_planted_hits" = "1" ]; then
    printf '  PASS: the causal-phrase detector fires on a planted attribution\n'; PASS=$((PASS+1))
else
    printf '  FAIL: the causal-phrase detector is blind — the check above proves nothing\n' >&2; FAIL=$((FAIL+1))
fi

echo '=== PLACEMENT is load-bearing, so it is asserted — not just the pattern ==='
# Rows are first-match-wins. A tmux row placed below a high-frequency row would
# be reached only for commands that miss everything above it, and (on a tree
# without #933) an already-seen tag above it ENDS the hook outright — so the
# rule would be dead on arrival for most commands. Assert BEHAVIOURALLY, not by
# reading the file: a command matching a tmux row AND a lower row must deliver
# the tmux one.
win tmux-order-1
run '{"tool_name":"Bash","tool_input":{"command":"git push --force origin dev && tmux kill-server"}}'
assert_ctx "tmux outranks force-push" "[tmux-kill-server]"
win tmux-order-2
run '{"tool_name":"Bash","tool_input":{"command":"pkill -u operator -f x ; tmux kill-window"}}'
# WAS `assert_ctx_absent "[pkill-self]"`, and that assertion is no longer the
# claim (your-org/nexus-code#1057). Every matching rule is now delivered, so
# pkill-self IS present — correctly, since the command really does build a
# `-f` match. What row order still buys, and what must not regress, is that the
# UNRECOVERABLE rule is read FIRST.
assert_ctx_first "  …and the unrecoverable rule is still read FIRST" "tmux-kill-window"
# Textual backstop: the FIRST rule row in the conf must carry the tmux tag, so a
# future insertion above it is a deliberate, visible act.
_first_tag=$(grep -vE '^[[:space:]]*(#|$)' "$CONF" | head -1 | cut -d'|' -f1)
if [[ "$_first_tag" == tmux-* ]]; then
    printf '  PASS: the first rule row in the conf is the tmux row (%s)\n' "$_first_tag"; PASS=$((PASS+1))
else
    printf '  FAIL: first conf row is %q, expected a tmux-* tag — the unrecoverable rule was demoted\n' "$_first_tag" >&2; FAIL=$((FAIL+1))
fi

echo '=== async-status: a bare `nohup … &` discards the exit status (#1071) ==='
# POSITION, NOT MENTION. Both arms, because the first draft of this row was
# `\bnohup\b[^;&]*&([^&]|$)` and it FIRED on `echo "we used to nohup things &"`
# — measured, not hypothesised. The population most likely to type that line is
# the agent working on this rule, which is how a detector gets tuned out.
win async-1
run '{"tool_name":"Bash","tool_input":{"command":"nohup ./producer.py &"}}'
assert_ctx "bare nohup … & fires" "[async-status]"
win async-2
run '{"tool_name":"Bash","tool_input":{"command":"nohup python big.py > out.log 2>&1 &"}}'
assert_ctx "…with redirections too" "async-run.sh"
win async-3
run '{"tool_name":"Bash","tool_input":{"command":"cd /tmp && nohup ./job.sh &"}}'
assert_ctx "…after an && separator" "[async-status]"
win async-4
run '{"tool_name":"Bash","tool_input":{"command":"(nohup ./j.sh &)"}}'
assert_ctx "…in a subshell" "[async-status]"

# The message must name the MECHANISM correctly. Measured on this host: the
# nohup CHILD survives the Bash tool call (reparented to init); what dies is
# the parent shell that would have reaped its status. A message claiming the
# job is killed would send the worker to fix the wrong thing.
win async-5
run '{"tool_name":"Bash","tool_input":{"command":"nohup ./p.py &"}}'
assert_ctx "message names the destroyed EXIT STATUS, not a killed job" "DESTROYS THE EXIT STATUS"
win async-6
run '{"tool_name":"Bash","tool_input":{"command":"nohup ./p.py &"}}'
assert_ctx "…and says an absent process is not a completed job" "ABSENT PROCESS IS NOT A COMPLETED JOB"
win async-7
run '{"tool_name":"Bash","tool_input":{"command":"nohup ./p.py &"}}'
assert_ctx "…and still says the worker OWNS the wake" "YOU STILL OWN THE WAKE"

echo '=== …and the cases it must NOT fire on ==='
win async-n1
run '{"tool_name":"Bash","tool_input":{"command":"echo \"we used to nohup things &\""}}'
assert_silent "prose MENTIONING nohup does not fire"
win async-n2
run '{"tool_name":"Bash","tool_input":{"command":"nohup echo hi && ls"}}'
assert_silent "a FOREGROUND nohup (&& is the operator) does not fire"
win async-n3
run '{"tool_name":"Bash","tool_input":{"command":"monitor/async-run.sh --desc x -- ./p.py"}}'
assert_silent "the prescribed replacement does not fire on itself"
win async-n4
run '{"tool_name":"Bash","tool_input":{"command":"git grep -n nohup monitor"}}'
assert_silent "searching for the word does not fire"

echo '=== #1057: EVERY matching rule is delivered, not just the first ==='
# The old behaviour was first-match-wins, and the sharpest instance was
# SELF-REFERENTIAL: the `pipe-status` arm is last in the hook, and the very
# incident its own message cites — `git push … | tail -2` reporting rc 0 for a
# server-rejected push — was pre-empted by the earlier `git-push` row. The arm
# fired and the worker was told about something else. That gap was invisible
# from either the arm or its tests, because every test asserted only that an
# arm MATCHES.
win md-selfref
run '{"tool_name":"Bash","tool_input":{"command":"git push origin dev | tail -2; rc=$?"}}'
assert_ctx_tags "the #1057 instance now delivers BOTH rules" 2
assert_ctx "  …including the one that used to be pre-empted" "[pipe-status]"
assert_ctx "  …alongside the one that used to pre-empt it" "[git-push]"
assert_ctx_first "  …in conf order: git-push is read first" "git-push"

win md-three
run '{"tool_name":"Bash","tool_input":{"command":"git push --force origin dev | tail -2 || echo x"}}'
assert_ctx_tags "a three-footgun command delivers three rules" 3
assert_ctx_first "  …force-push leads, as its row order intends" "force-push"

# THE CAP IS ANNOUNCED, WHICH IS WHAT SEPARATES IT FROM THE BUG. A cap the
# reader has to infer from absence is the defect one level up.
win md-cap
OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push --force origin dev | tail -2 || echo x"}}' \
      | NEXUS_FOOTGUN_MAX_DELIVER=1 bash "$HOOK"); RC=$?
assert_ctx_tags "a cap of 1 shows exactly one rule" 1
assert_ctx "  …and NAMES the withheld tags, never merely counts them" "WITHHELD by the per-command cap"
assert_ctx "  …naming git-push specifically" "git-push"
assert_ctx "  …and pipe-status specifically" "pipe-status"
assert_ctx "  …and says they were not marked seen" "NOT marked seen"

# A WITHHELD TAG IS NOT SPENT. Same window, second command: the tag the cap
# suppressed must still be able to fire, or the cap would silently consume
# warnings exactly as first-match-wins did.
run '{"tool_name":"Bash","tool_input":{"command":"echo x | tail -1 || echo y"}}'
assert_ctx "a tag withheld by the cap still fires later in the SAME window" "[pipe-status]"

# POTENCY / negative control for the cap notice: it must be ABSENT when
# nothing was withheld, or the assertion above would pass on every payload.
win md-nocap
run '{"tool_name":"Bash","tool_input":{"command":"git push origin dev"}}'
assert_ctx_tags "an uncapped single match delivers one rule" 1
assert_ctx_absent "  …and carries NO cap notice" "WITHHELD by the per-command cap"

# `block` still short-circuits: it exits 2, so the tool never runs and the
# advisory rows are moot. Purpose-built conf so the shipped one is untouched.
_mdconf=$(mktemp)
printf 'aaa-warn|warn|MDTRIG|advisory row\nzzz-block|block|MDTRIG|severe row\n' > "$_mdconf"
win md-block
OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"MDTRIG"}}' \
      | NEXUS_FOOTGUN_PATTERNS="$_mdconf" bash "$HOOK" 2>&1); RC=$?
if [[ $RC -eq 2 && "$OUT" == *"[zzz-block]"* && "$OUT" != *"[aaa-warn]"* ]]; then
    printf '  PASS: a block still short-circuits (rc 2, block message only)\n'; PASS=$((PASS+1))
else
    printf '  FAIL: block did not short-circuit (rc=%s out=%q)\n' "$RC" "$OUT" >&2; FAIL=$((FAIL+1))
fi
rm -f "$_mdconf"

echo '=== #1529: cc-update windows — every git verb off the read-only allowlist is BLOCKED ==='
# runb captures stderr too: a block is delivered on stderr at rc 2.
runb() { OUT=$(printf '%s' "$1" | bash "$HOOK" 2>&1); RC=$?; }
assert_blocked() { # <desc>  (rc 2 and the cc-update-git tag)
    if [[ $RC -eq 2 && "$OUT" == *"[cc-update-git]"* ]]; then
        printf '  PASS: %s\n' "$1"; PASS=$((PASS+1))
    else
        printf '  FAIL: %s (rc=%s out=%q)\n' "$1" "$RC" "$OUT" >&2; FAIL=$((FAIL+1))
    fi
}
assert_not_blocked() { # <desc>  (rc 0, and the cc-update-git tag absent)
    if [[ $RC -eq 0 && "$OUT" != *"[cc-update-git]"* ]]; then
        printf '  PASS: %s\n' "$1"; PASS=$((PASS+1))
    else
        printf '  FAIL: %s (rc=%s out=%q)\n' "$1" "$RC" "$OUT" >&2; FAIL=$((FAIL+1))
    fi
}
export NEXUS_WORKER_WINDOW="cc-auto-update"
# POTENCY: the directive's own case and the skeptic's evasions (w241sk e1..e8).
runb '{"tool_name":"Bash","tool_input":{"command":"git -C /x/nexus pull --ff-only"}}'
assert_blocked "evaluator: a bare pull (tracked upstream) is BLOCKED"
[[ "$OUT" == *"[pull]"* ]] && { printf '  PASS: …and the message names the denied verb\n'; PASS=$((PASS+1)); } || { printf '  FAIL: message does not name the verb (out=%q)\n' "$OUT" >&2; FAIL=$((FAIL+1)); }
runb '{"tool_name":"Bash","tool_input":{"command":"cd /x/nexus && git pull --rebase"}}'
assert_blocked "evaluator: pull --rebase is BLOCKED"
runb '{"tool_name":"Bash","tool_input":{"command":"git -C \"$NEXUS_ROOT\" worktree add work/nexus-code-cc-compat -b cc-compat/2.1.260"}}'
assert_blocked "evaluator: worktree add (even from local HEAD) is BLOCKED"
runb '{"tool_name":"Bash","tool_input":{"command":"tip=$(git rev-parse origin/dev) && git reset --hard \"$tip\""}}'
assert_blocked "evaluator: reset --hard to a ref read one command earlier is BLOCKED (the read-only rev-parse does not license the reset)"
runb '{"tool_name":"Bash","tool_input":{"command":"git -c advice.detachedHead=false checkout origin/dev"}}'
assert_blocked "evaluator: checkout through a -c option is BLOCKED"
runb '{"tool_name":"Bash","tool_input":{"command":"git clone https://github.com/your-org/nexus-code.git /tmp/fresh && bash /tmp/fresh/monitor/cc-harness/gate.sh"}}'
assert_blocked "evaluator: clone is BLOCKED"
runb '{"tool_name":"Bash","tool_input":{"command":"git fetch origin dev && git merge --ff-only FETCH_HEAD"}}'
assert_blocked "evaluator: fetch (allowed) followed by merge (denied) is BLOCKED — one denied verb suffices"
runb '{"tool_name":"Monitor","tool_input":{"command":"until git -C /x pull; do sleep 5; done"}}'
assert_blocked "evaluator: the Monitor tool is guarded too"
export NEXUS_WORKER_WINDOW="cc-restart-watchdog"
runb '{"tool_name":"Bash","tool_input":{"command":"git switch main"}}'
assert_blocked "watchdog: switch is BLOCKED"
# w241sk D1: read-only verbs whose OUTPUT is remote code, and two regex gaps.
export NEXUS_WORKER_WINDOW="cc-auto-update"
runb '{"tool_name":"Bash","tool_input":{"command":"git -C /x show origin/dev:monitor/cc-harness/gate.sh | bash -s -- --version 2.1.260"}}'
assert_blocked "D1: show <remote-ref>:<path> | bash is BLOCKED (remote code as output)"
runb '{"tool_name":"Bash","tool_input":{"command":"git -C /x cat-file -p FETCH_HEAD:monitor/cc-auto-update-apply.sh > /tmp/a.sh && bash /tmp/a.sh bump"}}'
assert_blocked "D1: cat-file -p FETCH_HEAD:<path> > f is BLOCKED"
runb '{"tool_name":"Bash","tool_input":{"command":"/usr/bin/git -C /x pull --ff-only"}}'
assert_blocked "D1: an absolute-path git binary is BLOCKED"
runb '{"tool_name":"Bash","tool_input":{"command":"git --git-dir=/x/.git --work-tree=/x pull --ff-only"}}'
assert_blocked "D1: --git-dir=… pull is BLOCKED"
runb '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"import subprocess; subprocess.run([\\\"git\\\",\\\"pull\\\"])\""}}'
assert_blocked "D1: a subprocess argv literal git pull is BLOCKED"
runb '{"tool_name":"Bash","tool_input":{"command":"git -C /x show HEAD:monitor/cc-harness/gate.sh | head -3; git -C /x diff --name-only HEAD..origin/dev"}}'
assert_not_blocked "D1 control: a LOCAL blob spec and a colon-less remote range pass"
runb '{"tool_name":"Bash","tool_input":{"command":"git -C /x show @{u}:monitor/cc-harness/gate.sh | bash"}}'
assert_blocked "D1 (round 3): the @{u} upstream blob spelling is BLOCKED"
runb '{"tool_name":"Bash","tool_input":{"command":"git -C /x show @{upstream}:monitor/cc-harness/gate.sh | sh"}}'
assert_blocked "D1 (round 3): …and @{upstream}"
# w241sk D2: the scope reads the spawn sites' marker files, not only this env.
mkdir -p "$STATE/cc-auto-update"; printf 'ccu-custom\n' > "$STATE/cc-auto-update/evaluator-window"
export NEXUS_WORKER_WINDOW="ccu-custom"
runb '{"tool_name":"Bash","tool_input":{"command":"git pull"}}'
assert_blocked "D2: a custom evaluator window named by the marker file is in scope"
# FAIL CLOSED: marker present, window unreadable → refused (direction of
# error stated in the header: it refuses an unidentified session, never
# admits the evaluator).
unset NEXUS_WORKER_WINDOW
runb '{"tool_name":"Bash","tool_input":{"command":"git pull"}}'
assert_blocked "D2 fail-closed: marker present + window unreadable (unknown) is REFUSED"
runb '{"tool_name":"Bash","tool_input":{"command":"git -C /x rev-parse HEAD"}}'
assert_not_blocked "D2 fail-closed control: …a read-only verb from the unknown window still passes"
export NEXUS_WORKER_WINDOW="ccu-custom"
rm -f "$STATE/cc-auto-update/evaluator-window"
runb '{"tool_name":"Bash","tool_input":{"command":"git pull"}}'
assert_not_blocked "D2 control: without the marker (and no env), the custom name is out of scope"
unset NEXUS_WORKER_WINDOW
runb '{"tool_name":"Bash","tool_input":{"command":"git pull"}}'
assert_not_blocked "D2 residual (stated in the header): no marker and no window — nothing to vouch for, out of scope"
# CONTROLS: read-only verbs pass, non-git `git` words pass, other windows pass.
export NEXUS_WORKER_WINDOW="cc-auto-update"
runb '{"tool_name":"Bash","tool_input":{"command":"git -C /x/nexus rev-parse HEAD"}}'
assert_not_blocked "evaluator: rev-parse passes"
runb '{"tool_name":"Bash","tool_input":{"command":"timeout 10 git -C /x/nexus fetch --quiet origin dev; git -C /x/nexus rev-list --count HEAD..origin/dev"}}'
assert_not_blocked "evaluator: fetch + rev-list pass (refs only, nothing executed)"
runb '{"tool_name":"Bash","tool_input":{"command":"git ls-remote origin refs/heads/dev && git log -1 --format=%H && git status --porcelain && git diff --name-only HEAD..origin/dev"}}'
assert_not_blocked "evaluator: ls-remote, log, status, diff pass"
runb '{"tool_name":"Bash","tool_input":{"command":"cat .git/HEAD; echo nexus-code.git; ls ~/.gitconfig; gh repo view your-org/nexus-code"}}'
assert_not_blocked "evaluator: .git/, nexus-code.git and gitconfig are not git verbs"
export NEXUS_WORKER_WINDOW="w999"
runb '{"tool_name":"Bash","tool_input":{"command":"git -C work/nexus-code-w999 checkout -b operator/w999"}}'
assert_not_blocked "an ordinary worker window is NOT in scope: its checkout in its own worktree passes"
export NEXUS_WORKER_WINDOW="footgun-test"

echo '=== #1059: procmatch-self says something DIFFERENT to a bracketed pattern ==='
# BOTH POLARITIES, because the arm was correct on one of them and the fix must
# not trade one direction for the other. Note the fix is the MESSAGE, not the
# trigger: bracketing defeats the grep's own hit and NOT a sibling agent's
# prompt-carried hit, so suppressing on brackets would close #1059 by opening
# your-org/nexus-code#1073 wider — a false negative on the case that matters.
win pmb-1
run '{"tool_name":"Bash","tool_input":{"command":"ps -u $USER -o args= | grep -c \"[t]muxwrap\""}}'
assert_ctx "a BRACKETED pattern still fires — the hazard survives bracketing" "[procmatch-self]"
assert_ctx "  …and the message CREDITS the half bracketing closes" "You BRACKETED the pattern"
assert_ctx "  …and names the half it does not" "IT CLOSES NOTHING ELSE"
assert_ctx_absent "  …and never tells a complying worker to bracket it again" "closes THIS ONE AND ONLY THIS ONE"

win pmb-2
run '{"tool_name":"Bash","tool_input":{"command":"ps aux | grep tmuxwrap"}}'
assert_ctx "an UNBRACKETED pattern fires with the other variant" "[procmatch-self]"
assert_ctx "  …which offers bracketing as closing ONLY the self-match" "closes THIS ONE AND ONLY THIS ONE"
assert_ctx_absent "  …and does not congratulate a worker who did not bracket" "You BRACKETED the pattern"

# Spellings that must classify as bracketed: quoting varies, and flags precede
# the pattern token.
win pmb-3
run '{"tool_name":"Bash","tool_input":{"command":"ps aux | grep -e \"[t]muxwrap\""}}'
assert_ctx "flags before the pattern are skipped (grep -e)" "You BRACKETED the pattern"
win pmb-4
run '{"tool_name":"Bash","tool_input":{"command":"ps aux | grep -F \u0027[t]muxwrap\u0027"}}'
assert_ctx "single-quoted bracketed pattern classifies as bracketed" "You BRACKETED the pattern"

# THE UNQUOTED SPELLING, RUN FROM A CWD THAT MAKES IT A LIVE GLOB. The first
# draft of the recogniser split the pattern token with `set -- $seg`, which
# also performs PATHNAME EXPANSION — so `[t]muxwrap` expanded to `tmuxwrap` in
# any cwd holding a file of that name, the brackets vanished, and the bracketed
# spelling was classified BARE. `monitor/tmuxwrap/` exists in this repo, so the
# trap is live rather than theoretical, and the misclassification depended on
# the CALLER'S CWD — a plausible wrong answer inside the fix for plausible
# wrong answers. This case runs the hook FROM `monitor/` on purpose; running it
# from anywhere else makes the assertion vacuous.
win pmb-glob
OUT=$(cd "$_test_dir/.." && printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ps aux | grep [t]muxwrap"}}' \
      | bash "$HOOK"); RC=$?
assert_ctx "an UNQUOTED bracketed pattern classifies as bracketed" "You BRACKETED the pattern"
# POTENCY for that case: the glob it would have expanded to must actually
# exist, or the regression it pins cannot occur and the assertion proves
# nothing.
if [[ -e "$_test_dir/../tmuxwrap" ]]; then
    printf '  PASS: the glob target monitor/tmuxwrap exists, so the case is not vacuous\n'; PASS=$((PASS+1))
else
    printf '  FAIL: monitor/tmuxwrap is gone — the pmb-glob case can no longer reproduce\n' >&2; FAIL=$((FAIL+1))
fi

# THE WIDENED MATCHER. `\bgrep\b` does not hold between `f` and `g`, so
# `fgrep`/`egrep` were silent while carrying the IDENTICAL hazard — measured,
# `ps -eo args= | {fgrep,egrep,rg} <nonce> | wc -l` all return the same phantom
# count as `grep`.
win pmw-1
run '{"tool_name":"Bash","tool_input":{"command":"ps -eo args= | fgrep tmuxwrap"}}'
assert_ctx "fgrep now fires (was a silent false negative)" "[procmatch-self]"
win pmw-2
run '{"tool_name":"Bash","tool_input":{"command":"ps -eo args= | egrep tmuxwrap"}}'
assert_ctx "egrep now fires (was a silent false negative)" "[procmatch-self]"
win pmw-3
run '{"tool_name":"Bash","tool_input":{"command":"ps -eo args= | rg tmuxwrap"}}'
assert_ctx "rg now fires (was a silent false negative)" "[procmatch-self]"

# THE DECLARED RESIDUAL, pinned as a NEGATIVE so it cannot be closed by
# accident. `awk`/`sed` carry the same hazard, but `ps … | awk '{print $1}'` is
# a column extraction and is the shape of the kill-list idiom CLAUDE.md
# blesses. Firing there would flag a prescribed remedy — the exact defect this
# section removes.
win pmw-4
run '{"tool_name":"Bash","tool_input":{"command":"kill $(ps -eo pid=,args= | awk \u0027/run-tests/ {print $1}\u0027 | monitor/proc-kill-authorized --filter)"}}'
assert_ctx_absent "the blessed awk kill-list idiom draws no procmatch-self" "[procmatch-self]"
win pmw-5
run '{"tool_name":"Bash","tool_input":{"command":"ps -p \"$pid\" -o args="}}'
assert_silent "a pid-scoped ps with no matcher stays silent"

echo '=== #1073: a WAIT keyed on argv gets the WAIT message, not the observe one ==='
# It used to get `procmatch-self`, whose advice is "bracket the pattern" —
# which does not touch this hazard at all. Measured live 2026-08-27: a
# correctly bracketed `[g]uards-for-diff` matched 12 processes, three of them
# sibling `claude`s in foreign sessions, so the loop cannot terminate on this
# host regardless of spelling.
win pw-1
# The payloads below deliberately spell the loop with `grep … >/dev/null`
# rather than `grep -q`. The arm keys on `ps … | <matcher>` and never looks at
# the flag, so nothing is lost — and a literal `<producer> | grep -q` anywhere
# under monitor/ is what test-sigpipe-assertion-lint.sh exists to keep out
# (your-org/nexus-code#622). A test payload is not executed, but it is exactly
# the text somebody copies.
run '{"tool_name":"Bash","tool_input":{"command":"until ps -eo args= | grep \u0027[g]uards-for-diff\u0027 >/dev/null; do sleep 5; done"}}'
assert_ctx "an argv-keyed WAIT delivers the wait arm" "[procmatch-wait-ps]"
assert_ctx_absent "  …and NOT the observe/kill arm, whose advice does not apply" "[procmatch-self]"
assert_ctx "  …the message names the premature-exit direction" "EXITS IMMEDIATELY"
assert_ctx "  …and the never-terminates direction" "WAITS FOREVER"
assert_ctx "  …and hands over a tool rather than a prohibition" "proc-exists-authorized"
assert_ctx "  …naming the refusal that makes it safe" "REFUSES"

win pw-2
run '{"tool_name":"Bash","tool_input":{"command":"while ps -eo args= | grep guards-for-diff >/dev/null; do sleep 5; done"}}'
assert_ctx "the while-spelling fires too" "[procmatch-wait-ps]"

win pw-3
run '{"tool_name":"Bash","tool_input":{"command":"until ps aux | fgrep -q myjob; do sleep 5; done"}}'
assert_ctx "the widened matcher reaches the wait shape as well" "[procmatch-wait-ps]"

# NEGATIVES: the remedies this arm hands out must not trip it, and neither may
# the pid-keyed waits already in this repo's own tests.
win pw-n1
run '{"tool_name":"Bash","tool_input":{"command":"monitor/proc-exists-authorized --until-present --token ar-abc123"}}'
assert_silent "the prescribed replacement does not fire on itself"
win pw-n2
run '{"tool_name":"Bash","tool_input":{"command":"until [[ \"$(tr \u0027\\0\u0027 \u0027 \u0027 < /proc/$SUP_PID/cmdline)\" == *launch.sh* ]]; do sleep 1; done"}}'
assert_silent "the repo's own pid-keyed /proc/cmdline wait stays silent"
win pw-n3
run '{"tool_name":"Bash","tool_input":{"command":"while kill -0 \"$pid\" 2>/dev/null; do sleep 5; done"}}'
assert_silent "the pid-keyed kill -0 wait stays silent alongside the new arm"
win pw-n4
run '{"tool_name":"Bash","tool_input":{"command":"ps -eo args= | grep -c myjob"}}'
assert_ctx_absent "a NON-wait ps|grep does not get the wait arm" "[procmatch-wait-ps]"

# ---- assertion-count guard ------------------------------------------------
# The summary reports assertions that RAN. One that never ran is invisible to
# it: a typo'd helper name is `command not found`, tallied by nothing, and the
# footer still says ALL TESTS PASSED with a quieter number. This suite has no
# conditional cases, so the count is exact. Bump it deliberately when adding a
# case; a DROP means a case stopped running.
# 103 -> 125: +22 for the pipe-status arm (your-org/nexus-code#1046) — 8 that
# must FIRE (the five field instances plus if-condition, `&&`, and `wc`) and 14
# that must NOT. The must-not half is what keeps the arm from being tuned out,
# and four of those eleven exist because `grep -c` was removed from the
# swallower set after measurement: it exits 1 on zero matches, so it is not an
# always-succeeds command and `| grep -c … || true` is a correct idiom (45 sites
# at `1475509`; see the self-referential note beside the grep -c cases above).
# 136 -> 186: +50 (+7 for the #1059 F2/F3 conf-row rewrite) for your-org/nexus-code#1057 / #1059 / #1073.
#   15 for multi-delivery (#1057): the self-referential instance now delivering
#      both rules, a three-rule command, the ANNOUNCED cap (named tags, not a
#      count), a withheld tag firing later in the same window, the cap notice
#      pinned ABSENT when nothing was withheld, and `block` still exiting 2.
#   16 for the pattern-aware procmatch-self message (#1059) — BOTH polarities,
#      since the arm was right in one direction and wrong in the other — plus
#      the widened fgrep/egrep/rg matcher and the awk residual pinned NEGATIVE.
#   12 for the argv-keyed WAIT arm (#1073), including the four negatives that
#      keep it off the pid-keyed waits this repo already contains.
# ── THE ZSH-IS-NOT-BASH ARM, AND ITS ORDER (your-org/nexus-code#1159, #1121) ──
# The guard carried 19 arms and NOT ONE for the zsh family, in a workspace whose
# every agent Bash call runs zsh. Both polarities are pinned, because the family
# has both and a reader who learned only the silent one will not recognise the
# loud one: the ARGUMENT form `cmd $VAR` fails loudly and UNIFORMLY across every
# cell of a matrix (which reads as an environment fault), the LOOP form
# `for x in $VAR` fails silently at rc 0.
win zws-arg
run '{"tool_name":"Bash","tool_input":{"command":"pytest $ARMS"}}'
assert_ctx "unquoted \$VAR in ARGUMENT position warns" "ZSH DOES NOT WORD-SPLIT"
win zws-loop
run '{"tool_name":"Bash","tool_input":{"command":"for tree in $TREES; do echo hi; done"}}'
assert_ctx "…and so does the LOOP form, whose failure is silent" "ZSH DOES NOT WORD-SPLIT"
win zws-quoted
run '{"tool_name":"Bash","tool_input":{"command":"pytest \"$ARMS\""}}'
assert_silent "the QUOTED form is the safe one and stays silent"
win zws-plain
run '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
assert_silent "a command with no parameter expansion stays silent"

# ARM ORDER IS THE ASSERTION HERE, not coverage. These two rows are the most
# GENERAL in the file — an unquoted `$VAR` appears in a large fraction of all
# commands — so they are placed LAST. If they were promoted above the specific
# rows, each command below would surface a word-splitting note INSTEAD of its
# real diagnosis, and the specific arm would be unreachable for that input:
# exactly `#1121`'s shape, where every arm is individually sound and the order
# makes one of them dead. Keyed on WHICH message comes back, so a reordering
# fails this rather than being discovered in production.
win zws-order-push
run '{"tool_name":"Bash","tool_input":{"command":"git push --force origin $BRANCH"}}'
assert_ctx "a general \$VAR row does not shadow the force-push boundary" "Force-push boundary"
win zws-order-wait
run '{"tool_name":"Bash","tool_input":{"command":"until [ -f $F ]; do sleep 30; done"}}'
assert_ctx "…nor the sentinel-wait arm" "An UNBOUNDED SENTINEL WAIT"

# ── your-org/nexus-code#1447: a COMMAND-predicate unbounded wait ─────────────
# The bracket form (`until [ -f X ]`) and the pgrep form each had a row; a wait
# whose predicate is an ordinary COMMAND had none, and it is the STRICTLY WORSE
# spelling — `until grep -q '^terminal' "$S"` waits for a token the producer
# never writes and so fails even when the job succeeds. 5h36m on the campaign
# critical path. The arm keys on the LOOP SHAPE, so all four spellings measured
# in one night fire, and the exemptions are an allowlist of blessed/owned forms.
echo '=== #1447: command-predicate unbounded waits WARN ==='
win ucw-real
run '{"tool_name":"Bash","tool_input":{"command":"until grep -q '"'"'^terminal'"'"' \"$S\" 2>/dev/null; do sleep 30; done"}}'
assert_ctx "the real 5h36m wait (grep -q on a status file) WARNS" "AN UNBOUNDED WAIT ON A COMMAND PREDICATE"
assert_ctx "  …and the message carries the on-disk vocabulary (rc= / ended=)" "ONLY lines are \`rc=\` and \`ended=\`"
assert_ctx "  …and names the typed bounded form" "async-run.sh --await --token"
win ucw-sacct-any
# The payload IS the `| grep -q` footgun under test. test-sigpipe-assertion-lint.sh
# flags that text in any shell file under monitor/ and has no per-line opt-out
# outside docs, so the pipe is assembled from a variable: the lint's subject is
# code, and this string is data that never runs.
_P='|'
run '{"tool_name":"Bash","tool_input":{"command":"until sacct -j A,B --format=State -P -n '"$_P"' grep -qE '"'"'COMPLETED|FAILED'"'"'; do sleep 60; done"}}'
assert_ctx "the grep-ANY over a two-job sacct (17 minutes early) WARNS" "AN UNBOUNDED WAIT ON A COMMAND PREDICATE"
assert_ctx "  …and the message states the EXISTENTIAL-vs-UNIVERSAL rule" "grep -q\` IS EXISTENTIAL"
win ucw-sacct-loop
run '{"tool_name":"Bash","tool_input":{"command":"for j in 1 2; do until s=$(sacct -j $j -X -n -o State | tr -d '"'"' '"'"'); [[ \"$s\" =~ ^(COMPLETED|FAILED).*$ ]]; do sleep 120; done; done"}}'
assert_ctx "a predicate that itself contains ';' (the jcfull sacct loop) WARNS" "AN UNBOUNDED WAIT ON A COMMAND PREDICATE"
win ucw-newline
run '{"tool_name":"Bash","tool_input":{"command":"until gh run view 1 --json status -q .status '"$_P"' grep -q completed\ndo sleep 60\ndone"}}'
assert_ctx "the newline spelling (no semicolons) WARNS" "AN UNBOUNDED WAIT ON A COMMAND PREDICATE"
# CONTROLS — the exemptions are an allowlist and each is a more specific owner.
win ucw-kill0
run '{"tool_name":"Bash","tool_input":{"command":"while kill -0 \"$pid\" 2>/dev/null; do sleep 15; done"}}'
assert_silent "the blessed pid wait (kill -0) stays SILENT under the new arm"
win ucw-read
run '{"tool_name":"Bash","tool_input":{"command":"while read -r f; do sleep 1; done < list"}}'
assert_silent "a while-read consumer loop is not a wait and stays SILENT"
win ucw-bracket-first
run '{"tool_name":"Bash","tool_input":{"command":"until [ -f \"$S\" ]; do sleep 30; done"}}'
assert_ctx "the bracket form still gets the sentinel row" "An UNBOUNDED SENTINEL WAIT"
assert_ctx_absent "  …and NOT the command-predicate row (owned elsewhere)" "AN UNBOUNDED WAIT ON A COMMAND PREDICATE"
win ucw-pgrep-first
run '{"tool_name":"Bash","tool_input":{"command":"until ! pgrep -f myjob; do sleep 5; done"}}'
assert_ctx_absent "the pgrep form is owned by procmatch-wait, not this arm" "AN UNBOUNDED WAIT ON A COMMAND PREDICATE"
# POTENCY: the arm is DATA. With the row removed from the conf the real wait
# is silent again — so the assertions above cannot pass vacuously through some
# other row that happens to mention the same words.
_ucw_conf=$(mktemp "$STATE/conf.XXXXXX")
grep -v '^unbounded-command-wait|' "$CONF" > "$_ucw_conf"
win ucw-potency
OUT=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"until grep -q x \"$S\"; do sleep 30; done"}}' \
      | NEXUS_FOOTGUN_PATTERNS="$_ucw_conf" bash "$HOOK"); RC=$?
assert_silent "POTENCY: with the row deleted from the conf, the real wait is SILENT"
rm -f "$_ucw_conf"

# ── your-org/nexus-code#1446: an existence query piped into head ─────────────
# `grep -r … | head -N` terminates on YES and scans everything on NO; three
# workers wedged >5h, panes reading working-background throughout.
echo '=== #1446: existence-query | head WARNS ==='
win eqh-grep
run '{"tool_name":"Bash","tool_input":{"command":"grep -raIl PR_22049 /shared/your-lab-m/metx_liver_met/ | head -5"}}'
assert_ctx "grep -r … | head (the 49m45s instance) WARNS" "AN EXISTENCE QUERY PIPED INTO"
assert_ctx "  …and the message names the reports/ silent zero and its remedy" "monitor/ng report-grep"
win eqh-reports
run '{"tool_name":"Bash","tool_input":{"command":"grep -raIl '"'"'X18527\\|X40917'"'"' work/ reports/ | head -20"}}'
assert_ctx "the 2h48m instance over reports/ WARNS" "AN EXISTENCE QUERY PIPED INTO"
win eqh-find
run '{"tool_name":"Bash","tool_input":{"command":"find /shared/your-lab-m/user/operator -maxdepth 6 -name '"'"'*.gmt'"'"' | head -3"}}'
assert_ctx "find … | head WARNS" "AN EXISTENCE QUERY PIPED INTO"
win eqh-file
run '{"tool_name":"Bash","tool_input":{"command":"grep -n foo file.txt | head -3"}}'
assert_silent "a NON-recursive grep | head is bounded by its file and stays SILENT"
win eqh-lsfiles
run '{"tool_name":"Bash","tool_input":{"command":"git ls-files | head -3"}}'
assert_silent "git ls-files | head is not a tree walk and stays SILENT"
win eqh-wc
run '{"tool_name":"Bash","tool_input":{"command":"grep -rn foo src/ | wc -l"}}'
assert_silent "grep -r | wc consumes everything by design and stays SILENT"

# 206 -> 226: +14 for #1447 (four firing spellings with three message-content
# pins, four allowlist controls, one row-deleted potency control) and +6 for
# #1446 (three firing shapes with one message pin, three bounded-form controls).
# 200 -> 206: +6 for the pipe-status disarm (your-org/nexus-code#904 leg G) — 4
# that must now stay SILENT (the two remedies this arm's own message prescribes)
# and 2 negative controls for the disarm, one of which pins that a FILENAME
# containing `pipefail` must not disarm anything.
# 226 -> 241: +15 for #1529 (the cc-update-git BLOCK arm: nine blocked shapes
# incl. one Monitor-tool and one watchdog-window case, one message-names-the-
# verb pin, four read-only/non-verb controls, one out-of-scope-window control).
# 241 -> 252: +11 for w241sk D1/D2 (five blocked shapes: remote blob via show
# and cat-file, absolute-path git, --git-dir=, subprocess literal; one local-
# blob control; marker-file scope, fail-closed unknown window + its read-only
# control, the no-marker control, and the no-marker-no-window residual).
# 252 -> 254: +2 for w241sk round 3 (the @{u} / @{upstream} blob spellings).
_EXPECTED_ASSERTIONS=254
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

