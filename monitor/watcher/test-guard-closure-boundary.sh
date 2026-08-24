#!/usr/bin/env bash
# The COVERAGE BOUNDARY of the silent-no-op guard fix, stated and tested.
#
# THE BOUNDARY, in one sentence:
#
#   Every SHIM-PRECONDITION guard — the check a launcher runs before the agent
#   starts, and only that kind — is closed at both ends: the launcher REFUSES
#   when it cannot locate the helper, and the helper returns exit 79
#   (NOT CHECKED) rather than 0 when it cannot adjudicate; NO OTHER KIND of
#   guard is closed, and the ones that cannot refuse without wedging a live
#   turn or the watcher instead have their shared precondition asserted once
#   at spawn, with every remaining site listed UNFIXED in the manifest below.
#
# THE AXIS MATTERS, and getting it wrong is subtle. The first version of this
# sentence was drawn along EXECUTION PATH — "every guard on the agent-SPAWN
# path is closed" — which is honest, tested, in-tree, and FALSE by one
# category: the deliverable-write probe (spawn-worker.sh, `$WRITE_PROBE` —
# cited by SYMBOL, never by line: three different line numbers for this one
# site had already accumulated across comments, and a stale citation is a
# small instance of the same drift) is a spawn-path
# guard that this same manifest asserts is UNFIXED. A bound drawn along the
# wrong axis contradicts its own evidence while looking rigorous.
#
# The mechanism does not vary by WHERE a guard runs; it varies by WHAT KIND of
# guard it is, because only the shim-precondition guard is the one this change
# owns end-to-end (its helper's exit contract included). So the sentence is
# drawn on guard KIND. "State the boundary in one sentence" is necessary but
# not sufficient — the sentence has to be drawn along the axis the mechanism
# actually varies on.
#
# WHY THIS FILE EXISTS. The residual unfixed sites are not the defect — an
# UNDECLARED boundary is. A closure claim that is true of a subset reads as
# true of the whole to anyone who does not diff it, and this workspace has now
# been bitten by that three times in one day (the `#272` spike-map class was
# declared "closed structurally, twice over" while closed against `.py` call
# sites only; its fourteenth site was a `.sh` heredoc builder no AST scan could
# ever see). So the boundary is written down above, and the assertions below
# are what stop it drifting away from the code silently.
#
# The manifest is the mechanism. A NEW member of the class cannot quietly join
# the unfixed pile: it reddens this suite, and the author must either fix it or
# add it to the manifest deliberately. That is the difference between "we know
# of 11" and "there are 11".
#
# Run: bash monitor/watcher/test-guard-closure-boundary.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

. "$_test_dir/_test_helpers.sh"

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

echo "=== 1. INSIDE the boundary — every spawn-path guard is fail-CLOSED ==="
# The spawn path is exactly: the three launchers spawn-worker.sh emits, and the
# one _respawn.sh emits. Enumerated from the source, not assumed, so a fourth
# launcher added later must also carry the block.
emitted=$(grep -c '^\$SHIM_GUARD_BLOCK$' "$REPO_ROOT/monitor/spawn-worker.sh")
# Leading whitespace varies between the three sites — anchor loosely or the
# count silently under-reports and this assertion passes vacuously.
heredocs=$(grep -cE '^[[:space:]]*cat > "\$LAUNCHER_TMP" <<LAUNCHER$' "$REPO_ROOT/monitor/spawn-worker.sh")
assert_eq "every launcher spawn-worker.sh emits carries the guard block" \
    "$emitted" "$heredocs"
# _respawn no longer carries the text — it substitutes @@ACTION@@=RESPAWN into
# the shared template. Assert the refusal reaches its launcher, at the source.
assert_contains "the shared template carries the refusal both callers emit" \
    "$(cat "$REPO_ROOT/monitor/guard-block.sh.in")" "REFUSING TO @@ACTION@@ — no shim precondition guard found"
# And the helper's side of the contract. The helper is assert-shims-wrapped.sh
# — NOT the deprecated assert-gh-wrapped.sh forwarder. That distinction is the
# whole reason this assertion is worth having: guard-block.sh.in searches
# assert-shims-wrapped.sh FIRST, so a third outcome that lived only in the
# forwarder would be unreachable dead code while every test in the tree still
# went green (your-org/nexus-code#612).
#
# The BEHAVIOURAL proof that each unadjudicable state returns 79 belongs to
# monitor/watcher/test-assert-shims-wrapped.sh, which runs the guard. What is
# pinned HERE is the pairing across the boundary: the helper can emit the third
# outcome, and the block that consumes it branches on that same value. Either
# half alone is satisfiable by a guard nobody calls.
asw="$REPO_ROOT/monitor/assert-shims-wrapped.sh"
assert_eq "the surviving helper — not the forwarder — carries the third outcome" \
    "$(grep -cE '^\s*exit 79$' "$asw")" "1"
assert_empty "…and every NOT CHECKED state routes to it rather than to a bare exit 0" \
    "$(awk '/NOT CHECKED/ { n = NR }
            /^[[:space:]]*exit 0$/ { if (n && NR - n <= 3) print "silent-exit-0 at line " NR }' "$asw")"
assert_contains "…and the forwarder delegates rather than answering itself" \
    "$(cat "$REPO_ROOT/monitor/assert-gh-wrapped.sh")" 'exec "$_agw_next"'
# The forwarder answers for itself in exactly ONE state — its successor is
# absent, which the successor cannot adjudicate on its own behalf — and that
# answer is 79. What it must never do is exit 0: printing "NOT checked" and
# returning a clean-pass value is this branch's original sin, and it is the
# partially-pulled tree of #614, not a hypothetical.
assert_empty "the forwarder has no silent pass — no exit 0 anywhere in it" \
    "$(grep -nE '^\s*exit 0$' "$REPO_ROOT/monitor/assert-gh-wrapped.sh" || true)"
assert_eq "…and its one self-answered state is the third outcome" \
    "$(grep -cE '^\s*exit 79$' "$REPO_ROOT/monitor/assert-gh-wrapped.sh")" "1"
assert_empty "…it never invents a refusal the successor did not make" \
    "$(grep -nE '^\s*exit 1$' "$REPO_ROOT/monitor/assert-gh-wrapped.sh" || true)"

echo
echo "=== 2. ON the boundary — the in-turn precondition is asserted at spawn ==="
# The two ENFORCEMENT hooks cannot refuse (a PreToolUse hook that exits
# non-zero on a missing dependency wedges every tool call), so their shared
# precondition is checked once, upstream, where a human reads it.
BLOCK="$SB/block.sh"
{ printf '#!/bin/bash\n'
  sed -e 's/@@WHO@@/spawn-worker/g' -e 's/@@ACTION@@/SPAWN/g' \
      -- "$REPO_ROOT/monitor/guard-block.sh.in"
} > "$BLOCK"
(( $(grep -cve '^[[:space:]]*$' "$BLOCK") >= 10 )) || {
    echo "FATAL: guard template unreadable or empty — a vacuous pass here would" >&2
    echo "       be this suite committing the defect it tests for." >&2; exit 1; }
! grep -q '@@' "$BLOCK" || { echo "FATAL: unsubstituted @@PLACEHOLDER@@ survived" >&2; exit 1; }

mkdir -p "$SB/root/monitor"
printf '#!/bin/sh\nexit 0\n' > "$SB/root/monitor/assert-gh-wrapped.sh"
chmod +x "$SB/root/monitor/assert-gh-wrapped.sh"
# jq present + patterns present → silent (the signal must mean something).
cp "$REPO_ROOT/monitor/bash-footgun-patterns.conf" "$SB/root/monitor/"
out=$(env NEXUS_ROOT="$SB/root" NEXUS_SPAWN_CODE_ROOT="$SB/root" bash "$BLOCK" 2>&1); rc=$?
assert_eq "healthy environment → spawn proceeds" "$rc" "0"
assert_not_contains "…and says nothing about in-turn guards" "$out" "IN-TURN GUARDS NOT ENFORCED"

# patterns file missing → the footgun guard's whole ruleset would no-op.
rm -f "$SB/root/monitor/bash-footgun-patterns.conf"
out=$(env NEXUS_ROOT="$SB/root" NEXUS_SPAWN_CODE_ROOT="$SB/root" bash "$BLOCK" 2>&1); rc=$?
assert_eq "missing pattern file does NOT block the spawn (a hook must not wedge)" "$rc" "0"
assert_contains "…but is announced" "$out" "IN-TURN GUARDS NOT ENFORCED"
assert_contains "…naming the missing file" "$out" "bash-footgun-patterns.conf"
assert_contains "…naming BOTH enforcement hooks it disables" "$out" "gh-write-guard.sh"
assert_contains "…including the blocking one" "$out" "bash-footgun-guard.sh"
assert_contains "…and denying it the status of a pass" "$out" "Not a pass"
# …and escalates to a refusal when the operator demands enforcement.
out=$(env NEXUS_ROOT="$SB/root" NEXUS_SPAWN_CODE_ROOT="$SB/root" \
      NEXUS_REQUIRE_SHIM_CHECK=1 bash "$BLOCK" 2>&1); rc=$?
assert_eq "NEXUS_REQUIRE_SHIM_CHECK=1 → refuses (78)" "$rc" "78"
assert_contains "…for the stated reason" "$out" "in-turn guards cannot run"

# jq missing → same treatment. Built by giving the block a PATH without jq.
JQLESS="$SB/jqless"; mkdir -p "$JQLESS"
for b in bash sh cat grep sed printf echo command test; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$JQLESS/$b"
done
cp "$REPO_ROOT/monitor/bash-footgun-patterns.conf" "$SB/root/monitor/"
out=$(env -i PATH="$JQLESS" NEXUS_ROOT="$SB/root" NEXUS_SPAWN_CODE_ROOT="$SB/root" \
      bash "$BLOCK" 2>&1); rc=$?
assert_eq "missing jq does NOT block the spawn" "$rc" "0"
assert_contains "…but is announced" "$out" "IN-TURN GUARDS NOT ENFORCED"
assert_contains "…naming jq specifically" "$out" "missing: jq"

echo
echo "=== 3. OUTSIDE the boundary — the MANIFEST of listed-but-unfixed sites ==="
# jq is an UNDECLARED HARD DEPENDENCY: absent, it silently changes behaviour at
# every site below. Case 2 makes that visible once at spawn; the sites
# themselves are deliberately unchanged. This manifest is what stops a twelfth
# joining them unnoticed.
#
# your-org/nexus-code#719: THE ENUMERATION IS NOW THE PROPERTY, NOT A SPELLING.
#
# This used to select the manifest's candidates with
#
#     grep -rlE 'command -v jq >/dev/null 2>&1 \|\| *(\{|exit 0|return 0)'
#
# which matches ONE spelling of the gate. `if ! command -v jq …; then … fi` was
# invisible to it. In the file whose stated purpose is "a NEW member of the
# class cannot quietly join the unfixed pile", the detector was itself the hole
# — "we know of 15" wearing the clothes of "there are 15".
#
# The naive repair — union the two regexes — repeats the mistake at one remove,
# and MEASURABLY so: of the `if !` sites, most REFUSE LOUDLY (`exit 2`, `die`),
# which is the CLOSED form. A regex union would have filed correctly-closed
# code onto an "unfixed" pile, and a third spelling (`type jq`, a `case` arm)
# would rejoin the invisible pile anyway.
#
# So the population is now every jq PROBE site, and each one must be classified
# into exactly one of three declared buckets. A new site lands in none of them
# and reddens the completeness assertion below.
#
# WHAT THIS BOUNDARY DOES *NOT* COVER — corrected after an independent skeptic
# measured the overclaim (#719 follow-up). The first version of this block said
# the population was covered "in ANY spelling, including ones nobody has
# invented yet". That was FALSE and measurably so: the probe was the literal
# string `command -v jq`, so a silent gate spelled `type jq` left the suite at
# 69/0 — blind. Reproduced independently before this correction.
#
# The probe is now the UNION `command -v|type|hash` + `jq`, which covers every
# spelling present in this tree (and `[ -x "$(command -v jq)" ]`, since that
# contains `command -v jq`). But a union is an ENUMERATION, not a proof of
# exhaustiveness: a `case` arm, a cached `$JQ` variable tested with `[ -n ]`, or
# a probe indirected through a helper would still be invisible.
#
# So state the two axes separately, because they are separately true:
#   * the FAILURE-ARM axis — what a gate does when jq is absent — IS closed:
#     every classified site is LOUD, FALLBACK or manifest, by construction.
#   * the PROBE axis — how the gate asks whether jq exists — is an enumerated
#     union, NOT closed. That is a declared limit, not a claim.
# Conflating them is the `#721` shape this repo has paid for twice: a boundary
# drawn correctly on one axis, stated as though it covered another.
#
#   LOUD      the gate REFUSES: non-zero exit / die. Nothing degrades, so it is
#             not a manifest member. Machine-checked below, not taken on trust.
#   FALLBACK  a real jq-free path that preserves behaviour. Also not a member.
#   DEGRADES  behaviour changes when jq is absent, silently or announced.
#             THIS is the manifest (`expected_jq`).
#
# `.md` is excluded: `monitor/install-prompt.md` names `command -v jq` in prose
# (a dependency checklist), which is documentation, not a gate.
mapfile -t jq_all < <(
    find "$REPO_ROOT/monitor" -type f ! -name '*.md' -print0 2>/dev/null \
    | xargs -0 grep -lE '(command -v|type|hash)[[:space:]]+jq' 2>/dev/null \
    | grep -v '/test-' | sed "s|^$REPO_ROOT/||" | LC_ALL=C sort
)
# `mapfile` from a `find -print0 | xargs -0` pipeline, NOT `grep -r`: the
# operator's interactive `grep` is a ugrep wrapper honouring .gitignore, and a
# recursive form returns a SILENT ZERO over an ignored tree (CLAUDE.md / #618).
# A zero here would empty the population and green EVERY assertion below. Note
# `xargs` execs a program, so the shell function is not in play and `command
# grep` must not be used (`#707`). Sanity-check the count so an enumeration
# that silently collapsed cannot pass as "nothing to classify":
assert_eq "the jq population is non-empty (a zero here would vacuously green everything)" \
    "$(( ${#jq_all[@]} > 20 ))" "1"

# LOUD — the gate refuses outright. Verified mechanically below.
jq_loud=(
    monitor/ci-run-execution.sh
    monitor/declare-no-wait.sh
    monitor/declare-wait.sh
    monitor/lit.sh
    monitor/nexus-root-sensitivity.sh
    monitor/resolve-settings.sh
    monitor/worker-health.sh
)
# `ci-run-execution.sh` (your-org/nexus-code#846) is LOUD by the same argument
# its own header makes for refusing rather than degrading: without jq it cannot
# read the jobs payload, and emitting rows whose execution column says
# `unexecuted` on the strength of not having looked is the one substitution that
# file exists to prevent. It `die`s (exit 2), and its documented caller fallback
# is the UNENRICHED rows — which read as `unknown` and keep a `failure` RED. So
# jq's absence costs a worse message and never a softer verdict, and nothing
# degrades at this site. Machine-checked below like every other LOUD member.
# FALLBACK — a jq-free path that preserves the behaviour, so jq's absence is
# not observable at this site. Each carries an else-branch or an equivalent
# non-jq route; classified by reading that branch, not by matching a shape.
#
# CLASSIFY THE FILE BY ITS WEAKEST SITE, NOT ITS FIRST. A file with several jq
# gates belongs here only if EVERY one of them has a jq-free path;
# `worker-heartbeat.sh` is the worked example of getting that wrong — see its
# entry in the manifest below.
#
# HONEST LIMIT, since this list also EXCUSES a file from the manifest: unlike
# `jq_loud` below, FALLBACK cannot be machine-checked. "There is a jq-free path
# and it preserves the behaviour" needs the else-branch read and compared, not
# pattern-matched. So each entry names the fallback it was verified against,
# and a reviewer can check the claim in one look rather than taking the
# membership on trust.
jq_fallback=(
    monitor/cc-harness/_lib.sh      # else: printf's the same config JSON by hand
    monitor/claude-loop.sh          # if -z: sed-parses the same action-log rows
    monitor/hooks/notify-permission.sh  # if -z: `case` glob on the raw payload
    monitor/retire-preflight.sh     # else: sed-extracts the same session_id
    monitor/window-session-id.sh    # documented fallback, on empty AND on absent
)
# DEGRADES — the manifest. Derived by SUBTRACTION from the measured population
# rather than re-listed, so the two can never disagree: anything not declared
# LOUD or FALLBACK is a manifest member by construction, and the assertion
# below is what forces a new one to be a decision.
jq_sites=()
for _f in "${jq_all[@]}"; do
    _cls=degrades
    for _l in "${jq_loud[@]}"     "${jq_fallback[@]}"; do
        [[ "$_f" == "$_l" ]] && { _cls=other; break; }
    done
    [[ "$_cls" == degrades ]] && jq_sites+=( "$_f" )
done
# LC_ALL=C on that sort is load-bearing, not tidiness. Glibc collation in a
# UTF-8 locale IGNORES leading punctuation, so `monitor/_submit_evidence.sh`
# sorts BEFORE `monitor/cc-…` under C and AFTER it under en_US.UTF-8 — and
# the manifest below is an ordered comparison. Every previous member begins
# with a letter, so the order was locale-invariant by accident and the
# fragility stayed latent until the first `_`-prefixed member arrived
# (your-org/nexus-code#665). Unpinned, this suite is green on a C-locale CI
# runner and red on the operator's own box, or the reverse. The expected
# array below is in C order.
expected_jq=(
    # your-org/nexus-code#665. A DECISION, not a regeneration. The content
    # marker's transcript scan needs jq; without it `se_submission_with_digest`
    # returns `unknown` and the `paste-unconfirmed` detector falls back to its
    # pre-#665 temporal surface. That degradation is DESIGNED and three-valued
    # rather than silent — but it is still "jq absent changes behaviour", which
    # is what this manifest tracks, so it belongs here.
    #
    # NOTE FOR WHOEVER OWNS THIS SUITE (your-org/nexus-code#719), CORRECTED:
    # the grep above matches a SPELLING — `command -v jq … || {` — and misses
    # `if ! command -v jq …; then … fi`, of which there are 7 on this tree.
    #
    # An earlier version of this note concluded "the manifest asserts 15 of 21"
    # and singled out worker-health.sh as severe. That was WRONG, and wrong in
    # this file's own signature way: it counted syntax rather than the
    # population the manifest tracks. This manifest's class is the SILENT
    # degrade — its detector deliberately matches the `|| {` / `exit 0` /
    # `return 0` arms — and reading the failure arm of all seven:
    #
    #   declare-no-wait.sh    exit 2   loud refusal — the CLOSED form
    #   declare-wait.sh       exit 2   loud refusal — CLOSED
    #   resolve-settings.sh   exit 4   loud refusal — CLOSED (cites #614)
    #   worker-health.sh      exit 2   loud refusal — CLOSED
    #   watcher/_unstick.sh   unstick_log WARN + return 1   announced
    #   paste-followup.sh     VERIFY=0 + reason              announced, 3-valued
    #   _submit_evidence.sh   printf 'unknown'               designed 3-valued
    #
    # Four are the FIXED form and three announce. Widening the detector on the
    # strength of that count would have added correctly-closed sites to an
    # "unfixed" pile — the opposite of the intended effect.
    #
    # What survives: the detector is still spelling-shaped, so a genuinely
    # SILENT `if ! command -v jq …; then … fi` would be invisible to it. That
    # is a real (if currently unrealised) hole, and #719 now says so. Fixing it
    # means matching the property — a jq gate whose failure arm does not fail
    # loudly — which changes this suite's declared boundary and belongs there,
    # not on #665's PR.
    monitor/_submit_evidence.sh
    monitor/cc-auto-update-apply.sh
    monitor/guard-block.sh.in
    monitor/hooks/async-launch-detect.sh
    monitor/hooks/bash-footgun-guard.sh
    monitor/hooks/decision-emit.sh
    monitor/hooks/decision-mark-unresolved.sh
    monitor/hooks/gh-write-guard.sh
    # your-org/nexus-code#719. Joined when the enumeration became the property
    # rather than the `|| {` spelling. jq absent → the whole capture block is
    # skipped and the hook `exit 0`s: NOTHING is recorded, to neither the raw
    # nor the structured log, with no message. There is no else-branch. This is
    # the silent member the old detector was structurally unable to see, and it
    # is an observability surface going dark rather than announcing.
    monitor/hooks/notification-record.sh
    monitor/hooks/orchestrator-session-pin.sh
    monitor/hooks/over-limit-emit.sh
    monitor/hooks/turn-failure-emit.sh
    monitor/ng
    monitor/pane-state.sh
    # #719. Announced, three-valued: VERIFY=0 with UNVERIFIABLE_REASON naming
    # jq. A designed degrade, and a degrade all the same — same footing as
    # _submit_evidence.sh above.
    monitor/paste-followup.sh
    # #719. `session_id` silently becomes "" in the reply record. Declared
    # best-effort at the site (a liveness HINT), which is why it is a manifest
    # member and not a bug: the behaviour change is real but bounded.
    monitor/request-channel.sh
    monitor/spawn-worker.sh
    # #719. `return 1` with no message — the update check reports "unreachable"
    # and fails safe, so a jq-less host stops seeing CC updates without saying
    # so.
    monitor/watcher/_cc_update.sh
    monitor/watcher/_idle_probe.sh
    # #719. Two sites, both `return 1` silently: the read-only-FS incident
    # GitHub escalation and its recovery close-comment. The failure mode is
    # that the durable GitHub record of an outage is never written.
    monitor/watcher/_lib.sh
    # #719. Two sites of DIFFERENT kinds, which is why the file is listed once
    # and annotated: :577 announces (`unstick_log WARN … action=jq-missing`),
    # :932 is SILENT — the orchestrator-ack fast path is skipped and case B
    # falls through to the timeout instead.
    monitor/watcher/_unstick.sh
    # #719. THE ENTRY THAT SHOWS WHY A FILE IS CLASSIFIED BY ITS WEAKEST SITE.
    # It has THREE jq gates and only the last one has an `else`:
    #   :249  else-branch emits a minimal heartbeat by hand   FALLBACK
    #   :126  no else — event_name / tool_name / session_id / message /
    #         notification_type / schedule_delay_seconds all stay EMPTY
    #   :213  no else — preserved_waits stays `[]`, so `external_waits` and
    #         `scheduled_wakeup_at` are not carried forward
    # So the heartbeat is still WRITTEN without jq, but it loses the async
    # signals — and the file says so itself at :285 ("A jq-less worker is
    # already degraded; the classifier falls through to pane-footer parsing").
    # That is "jq absent changes behaviour", which is what this manifest
    # tracks. Reading only the site with the `else` files it as FALLBACK and
    # quietly removes a real degrade from the manifest.
    monitor/worker-heartbeat.sh
)
assert_eq "the jq-dependent set is exactly the manifest (a new one must be a DECISION)" \
    "$(printf '%s\n' "${jq_sites[@]}")" "$(printf '%s\n' "${expected_jq[@]}")"

# THE COMPLETENESS ASSERTION — what makes the manifest a claim about the TREE
# rather than about a regex. Every measured site must be classified into
# exactly one bucket; a new `command -v jq` anywhere under monitor/ lands in
# none and reddens here, in ANY spelling, including ones nobody has invented.
assert_eq "every \`command -v jq\` site is classified (LOUD | FALLBACK | manifest)" \
    "$(printf '%s\n' "${jq_all[@]}")" \
    "$(printf '%s\n' "${jq_loud[@]}" "${jq_fallback[@]}" "${expected_jq[@]}" | LC_ALL=C sort)"

# …and neither exemption list may carry a STALE entry. Without this, deleting a
# file or removing its gate would leave a phantom exemption that silently
# absorbs a future file of the same name.
_stale=()
for _f in "${jq_loud[@]}" "${jq_fallback[@]}"; do
    _hit=no
    for _a in "${jq_all[@]}"; do [[ "$_f" == "$_a" ]] && { _hit=yes; break; }; done
    [[ "$_hit" == no ]] && _stale+=( "$_f" )
done
assert_eq "no stale LOUD/FALLBACK exemption (each must still carry a jq gate)" \
    "${_stale[*]:-none}" "none"

# The LOUD list is the one that EXCUSES a file from the manifest, so it is the
# one that must not be taken on trust — an entry misclassified as LOUD removes
# a real degrade from the manifest silently. Machine-check the claim: the gate's
# own arm has to carry a non-zero exit or a `die`.
#
# HERESTRING, not `producer | grep -q`. This file runs under `set -uo pipefail`
# (line 48), and `grep -q` EXITS AT THE FIRST MATCH — which SIGPIPEs the
# producer, whose non-zero status pipefail then propagates as the pipeline's.
# So a LOUD file whose gate really does carry `exit 2` could be reported
# NOT-loud, purely because the match came early enough to close the pipe. The
# window is real but narrow (these are 4-line greps), which is exactly what
# makes it survive casual testing and ambush later — `test-sigpipe-assertion-
# lint.sh` flagged this line and is the reason it is written this way.
#
# SITE-GRANULAR, and this is the second correction to this one check
# (your-org/nexus-code#719 follow-up). The first version asked only whether the
# FILE contained a refusal anywhere — `grep -A3 … | grep -q` concatenates every
# site, so ONE refusing gate vouched for all of them. An independent skeptic
# planted a SECOND, silent `command -v jq` gate in `worker-health.sh` (LOUD) and
# the suite stayed 69/0 — BLIND. Reproduced here before this rewrite.
#
# That is precisely the rule this suite introduced as its own headline lesson —
# CLASSIFY A FILE BY ITS WEAKEST SITE — written into the FALLBACK block and left
# unenforced in the very block that claims "machine-checked, not taken on
# trust". A guard that states a rule and exempts itself from it is worse than no
# guard, because the claim is what gets read.
#
# Now EVERY site must refuse, and the refusal must sit on a NON-COMMENT line:
# `\bdie\b` used to match prose, so a silent gate with `# we do not die here`
# nearby passed (69/0, measured). Comments are stripped before matching.
_loud_site_tally() {   # <file> -> "<refusing>/<sites>"
    awk '
      { line = $0; sub(/#.*/, "", line) }          # strip comments: prose must not vouch
      # No `next`: the probe LINE itself is part of the window. The common
      # one-liner `command -v jq >/dev/null || die "jq required"` carries its
      # refusal on the same line, and skipping it scored that site 0/1.
      line ~ /(command -v|type|hash)[[:space:]]+jq/ { n++; win = 4; ref[n] = 0 }
      win > 0 {
          if (line ~ /exit[[:space:]]+[1-9][0-9]*/ || line ~ /(^|[^[:alnum:]_])die([^[:alnum:]_]|$)/)
              ref[n] = 1
          win--
      }
      END { r = 0; for (i = 1; i <= n; i++) r += ref[i]; printf "%d/%d", r, n }
    ' "$1"
}
_notloud=()
for _f in "${jq_loud[@]}"; do
    _tally=$(_loud_site_tally "$REPO_ROOT/$_f")
    [[ "${_tally%/*}" == "${_tally#*/}" && "${_tally#*/}" != 0 ]] \
        || _notloud+=( "$_f($_tally)" )
done
assert_eq "every LOUD entry really refuses (non-zero exit or die at its gate)" \
    "${_notloud[*]:-none}" "none"

# Of those, the two ENFORCEMENT hooks are the high-severity members: losing an
# observability hook loses visibility, losing these loses a GUARANTEE.
assert_contains "gh-write-guard is on the manifest (GitHub identity, #497)" \
    "$(printf '%s\n' "${jq_sites[@]}")" "monitor/hooks/gh-write-guard.sh"
assert_contains "bash-footgun-guard is on the manifest (can exit 2 to BLOCK)" \
    "$(printf '%s\n' "${jq_sites[@]}")" "monitor/hooks/bash-footgun-guard.sh"
# Proof they really are enforcement, not observability — so the severity claim
# above is checked rather than asserted.
n_block=$(grep -c 'exit 2' "$REPO_ROOT/monitor/hooks/bash-footgun-guard.sh")
if (( n_block >= 1 )); then
    ok_blocking=yes
else
    ok_blocking=no
fi
assert_eq "…and bash-footgun-guard really can block a tool call (exit 2)" "$ok_blocking" "yes"

# pane-state.sh is on the list but is NOT silent — it is the one site this PR
# converted to an announced outcome. Pin that so it cannot regress into the
# silent majority.
assert_contains "pane-state's jq gate announces rather than degrades" \
    "$(grep -A1 'command -v jq' "$REPO_ROOT/monitor/pane-state.sh")" "unknown:no-jq"

# The non-jq members of the class, each verified STILL PRESENT so that this
# manifest describes the tree rather than a memory of it. If one is fixed, this
# reddens and the manifest must be updated — which is the intended workflow.
assert_eq "UNFIXED: the deliverable-write probe is still gated with no else" \
    "$(grep -c 'if \[ -x "\$WRITE_PROBE" \]; then' "$REPO_ROOT/monitor/spawn-worker.sh")" "1"
assert_contains "…still documents itself as a silent skip, and now cross-refs the boundary" \
    "$(grep -B30 'if \[ -x "\$WRITE_PROBE" \]; then' "$REPO_ROOT/monitor/spawn-worker.sh")" "silent skip"
assert_contains "UNFIXED: the footgun ruleset is gated with no else" \
    "$(grep -c 'if \[ -f "\$_pattern_file" \]; then' "$REPO_ROOT/monitor/hooks/bash-footgun-guard.sh")" "1"
assert_contains "…and the write-probe site cross-refs this boundary file" \
    "$(grep -B30 'if \[ -x "\$WRITE_PROBE" \]; then' "$REPO_ROOT/monitor/spawn-worker.sh")" \
    "test-guard-closure-boundary.sh"
assert_contains "…naming the axis, so the path-drawn reading cannot return" \
    "$(grep -B30 'if \[ -x "\$WRITE_PROBE" \]; then' "$REPO_ROOT/monitor/spawn-worker.sh")" \
    "NOT on execution"
assert_contains "UNFIXED: the orchestrator idle guard probes pane-state under [ -x ]" \
    "$(grep -c 'if \[\[ -x "\$NEXUS_ROOT/monitor/pane-state.sh" \]\]; then' "$REPO_ROOT/monitor/watcher/main.sh")" "1"

echo
echo "=== 4. ONE SOURCE — the two launchers cannot diverge ==="
# Two hand-maintained copies of a guard is how the next divergence lands, and
# a guard silently diverged from its twin is a cousin of this defect class:
# both ends look enforced, only one is. So there is exactly one source.
TPL="$REPO_ROOT/monitor/guard-block.sh.in"
assert_eq "the guard block has a single source file" "$([ -r "$TPL" ] && echo yes)" "yes"
assert_eq "spawn-worker.sh reads it" \
    "$([ "$(grep -c 'guard-block.sh.in' "$REPO_ROOT/monitor/spawn-worker.sh")" -ge 1 ] && echo yes)" "yes"
assert_eq "_respawn.sh reads the SAME file" \
    "$([ "$(grep -c 'guard-block.sh.in' "$REPO_ROOT/monitor/watcher/_respawn.sh")" -ge 1 ] && echo yes)" "yes"
assert_empty "neither sources it (sourced-helper skew is the watcher hazard)" \
    "$(grep -nE '^\s*\.\s+.*guard-block\.sh\.in' \
        "$REPO_ROOT/monitor/spawn-worker.sh" "$REPO_ROOT/monitor/watcher/_respawn.sh" || true)"
# No inline copy may reappear in either caller.
assert_empty "no inline copy of the search loop survives in spawn-worker.sh" \
    "$(grep -n 'for _nx_name in assert-shims-wrapped.sh' "$REPO_ROOT/monitor/spawn-worker.sh" || true)"
assert_empty "…nor in _respawn.sh" \
    "$(grep -n 'for _nx_name in assert-shims-wrapped.sh' "$REPO_ROOT/monitor/watcher/_respawn.sh" || true)"
# An absent template must refuse, never emit an empty block.
assert_contains "spawn-worker refuses on a missing template" \
    "$(grep -A3 'GUARD_BLOCK_TEMPLATE=' "$REPO_ROOT/monitor/spawn-worker.sh")" "REFUSING TO SPAWN"
assert_contains "_respawn refuses on a missing template" \
    "$(grep -A12 '_rs_tpl=' "$REPO_ROOT/monitor/watcher/_respawn.sh")" "REFUSING TO RESPAWN"
# Both substitutions must be applied, or a launcher ships a literal @@WHO@@.
for who in spawn-worker _respawn; do
    assert_contains "the $who caller substitutes @@WHO@@" \
        "$(grep -h "s/@@WHO@@/$who/g" "$REPO_ROOT/monitor/spawn-worker.sh" \
             "$REPO_ROOT/monitor/watcher/_respawn.sh" 2>/dev/null)" "@@WHO@@/$who"
done

# EVERY fixture that installs a launcher-composing script into a fake tree
# must supply the template, or it gets exit 78 and fails for a reason
# unrelated to what it tests. Discovering those one CI round at a time is the
# same "verified a subset" failure this suite exists to stop, applied to test
# fixtures rather than production guards — it cost three round trips.
#
# BOTH callers are enumerated, not just spawn-worker.sh. The first version of
# this check covered spawn-worker only and therefore missed
# test-respawn-loop-integration.sh, whose fixture installs _respawn.sh — the
# manifest itself had the too-narrow boundary this file is about. Its own
# failure message had anticipated the class ("check that every file
# _respawn.sh sources is copied into the fixture"), which is why it was
# diagnosable at all.
#
# THE PREDICATE IS AN INSTALL, NOT A MENTION — and that distinction is the
# whole value of this check. It first read `grep -q 'guard-block.sh.in'`, which
# tests whether the filename APPEARS in the fixture. Every fixture here carries
# an explanatory comment naming the template directly above its `cp`, so
# deleting ONLY the cp line — the realistic regression — left the mention alive
# and the manifest green. Measured across all seven covered fixtures: it caught
# ONE. A check that asserts a proxy (the name is mentioned) rather than the
# property (the file is installed) is the defect this suite exists to police,
# committed by this suite, defeated by this PR's own comments.
#
# Both the population and the predicate are therefore anchored to a real
# `cp` COMMAND at line start. That also removed a self-match: this file used to
# appear in its own population, matching the population regex on its own prose
# and on its own detector source while installing nothing, then passing the
# mention check on those same comments — two errors cancelling to green. It is
# now out of the population by construction rather than by exemption.
#
# WHAT THE DETECTOR DOES NOT SEE — declared, not chased, and declared on the
# right AXIS. The first version of this paragraph said "literal `cp` lines
# only ... `install`, `rsync`, `tar` are invisible", which names the TOOL as
# the axis. The mechanism never varied on the tool; it varied on POSITION. A
# literal `cp` was invisible unless it BEGAN the line, so `(( flag )) && cp ...`
# was missed - an idiom already in use one file away, at
# monitor/watcher/test-bootstrap-install.sh:99. Naming the wrong axis is the
# failure this file's own header teaches, and it happened here for the third
# time in this change, in the very sentence written to declare what the
# detector misses.
#
# Match positions are therefore line-start OR after a command separator
# (&&, ||, ;). That closes the condition-prefixed case WITHOUT dropping the
# line-start anchor - dropping it would reinstate the prose self-match removed
# above, a worse trade.
#
# The residual bound, on the axis that actually governs: a `cp` reached by a
# route none of those positions describe (inside a pipeline, an `eval`, a loop
# body under other syntax), and any installer that is not `cp` at all
# (`install`, `rsync`, `tar`). No such fixture exists today, so this is a
# future-author trap rather than a present hole.
#
# The predicate carries the same asymmetry in the SAFE direction: a fixture
# installing the template by a route the positions miss is reported MISSING -
# a false RED, which is loud and self-correcting, never a silent pass.
#
# The GLOB arm (`/watcher/_*.sh`) is load-bearing: test-respawn-loop-integration
# installs _respawn.sh via `cp "$SRC"/monitor/watcher/_*.sh`, so a detector
# matching literal filenames does not see it. The first version of this check
# matched literals only and its own negative control caught the gap — a
# too-narrow PATTERN is the same defect as a too-narrow boundary, one level
# down, which is why the control below strips the template from the
# glob-installing fixture specifically.
#
# EXEMPT: a fixture that installs a caller but never composes a launcher
# needs nothing. Exemptions are listed HERE, with a reason, so they are a
# decision rather than an omission.
tpl_exempt="test-entry.sh"          # sources _respawn.sh for resolver
                                    # functions; never calls
                                    # _respawn_compose_launcher (asserted below)
missing_tpl=""
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    base=$(basename "$f")
    case " $tpl_exempt " in *" $base "*) continue ;; esac
    grep -qE '(^|&&|\|\||;)[[:space:]]*cp .*guard-block\.sh\.in' "$f" || missing_tpl+="$base "
done < <(grep -rlE '(^|&&|\|\||;)[[:space:]]*cp .*(SPAWN_REAL|SCRIPT_REAL|spawn-worker\.sh|_respawn\.sh|/watcher/_\*\.sh|/monitor/\*\.sh)' \
             "$REPO_ROOT/monitor/watcher"/test-*.sh 2>/dev/null | sort)
assert_empty "every fixture installing spawn-worker.sh OR _respawn.sh installs the template" \
    "$missing_tpl"
# The exemption must stay true: if test-entry ever composes a launcher, it
# needs the template and this silently stops covering it.
assert_eq "the exemption still holds (test-entry composes no launcher)" \
    "$(grep -c '_respawn_compose_launcher' "$REPO_ROOT/monitor/watcher/test-entry.sh")" "0"

echo
echo "=== 5. DURABLE SINK — an announce that goes nowhere is unobservable ==="
# Both announce-and-proceed outcomes (exit 79, and in-turn guards unenforced)
# are the cases where the spawn CONTINUES. Without a durable record there is
# no way to establish afterwards that a worker ran unverified.
assert_contains "the template defines a state-dir sink" "$(cat "$TPL")" "guard-unverified.log"
assert_contains "…used by the exit-79 outcome" \
    "$(grep -A6 '"$_nx_rc" = 79' "$TPL")" "_nx_note"
assert_contains "…and by the in-turn outcome" \
    "$(grep -A2 'if \[ -n "$_nx_missing" \]' "$TPL")" "_nx_note"
assert_contains "…and the sink is best-effort, never able to wedge a spawn" \
    "$(sed -n '/^_nx_note() {/,/^}/p' "$TPL")" "|| true"
# Behavioural: the log actually gets a row, and the announcement still reaches stderr.
mkdir -p "$SB/sink/monitor/.state"
printf '#!/bin/sh\nexit 79\n' > "$SB/sink/monitor/assert-gh-wrapped.sh"
chmod +x "$SB/sink/monitor/assert-gh-wrapped.sh"
cp "$REPO_ROOT/monitor/bash-footgun-patterns.conf" "$SB/sink/monitor/"
out=$(env NEXUS_ROOT="$SB/sink" NEXUS_SPAWN_CODE_ROOT="$SB/sink" \
      NEXUS_WORKER_WINDOW=sinkwin bash "$BLOCK" 2>&1); rc=$?
assert_eq "exit 79 still proceeds" "$rc" "0"
assert_contains "…announces on stderr" "$out" "NOT CHECKED"
assert_contains "…and lands a durable row" \
    "$(cat "$SB/sink/monitor/.state/guard-unverified.log" 2>/dev/null)" "NOT CHECKED"
assert_contains "…attributed to the window" \
    "$(cat "$SB/sink/monitor/.state/guard-unverified.log" 2>/dev/null)" "sinkwin"
# MODE (your-org/nexus-code#484): this is an EVIDENCE log — its only purpose
# is to establish after the fact that an agent started unverified — so a
# group-writable one defeats its own purpose. Driven under umask 000, the
# worst case, where a bare `>>` would yield 0666.
mkdir -p "$SB/mode/monitor/.state"
cp "$REPO_ROOT/monitor/_log-mode.sh" "$SB/mode/monitor/_log-mode.sh"
printf '#!/bin/sh\nexit 79\n' > "$SB/mode/monitor/assert-gh-wrapped.sh"
chmod +x "$SB/mode/monitor/assert-gh-wrapped.sh"
cp "$REPO_ROOT/monitor/bash-footgun-patterns.conf" "$SB/mode/monitor/"
( umask 000; env NEXUS_ROOT="$SB/mode" NEXUS_SPAWN_CODE_ROOT="$SB/mode" \
    bash "$BLOCK" >/dev/null 2>&1 )
assert_eq "the evidence log is created 0640, never group-writable" \
    "$(stat -c %a "$SB/mode/monitor/.state/guard-unverified.log" 2>/dev/null)" "640"
# …and identically when the helper is NOT reachable: the inline fallback is an
# equivalent implementation, not a weaker path. If these two ever diverge the
# fallback has silently become a downgrade.
mkdir -p "$SB/mode2/monitor/.state"
printf '#!/bin/sh\nexit 79\n' > "$SB/mode2/monitor/assert-gh-wrapped.sh"
chmod +x "$SB/mode2/monitor/assert-gh-wrapped.sh"
cp "$REPO_ROOT/monitor/bash-footgun-patterns.conf" "$SB/mode2/monitor/"
( umask 000; env NEXUS_ROOT="$SB/mode2" NEXUS_SPAWN_CODE_ROOT="$SB/mode2" \
    bash "$BLOCK" >/dev/null 2>&1 )
assert_eq "…and 0640 too via the inline fallback (no _log-mode.sh present)" \
    "$(stat -c %a "$SB/mode2/monitor/.state/guard-unverified.log" 2>/dev/null)" "640"

# The "could NOT record" branch must be REACHABLE. A message no test can
# trigger is the same defect one level down: it looks like a handled case and
# is really dead code. Driven with a read-only .state, which is the realistic
# shape (a tree the agent cannot write to).
mkdir -p "$SB/roflag/monitor/.state"
printf '#!/bin/sh\nexit 79\n' > "$SB/roflag/monitor/assert-gh-wrapped.sh"
chmod +x "$SB/roflag/monitor/assert-gh-wrapped.sh"
cp "$REPO_ROOT/monitor/bash-footgun-patterns.conf" "$SB/roflag/monitor/"
chmod 500 "$SB/roflag/monitor/.state"
out=$(env NEXUS_ROOT="$SB/roflag" NEXUS_SPAWN_CODE_ROOT="$SB/roflag" bash "$BLOCK" 2>&1); rc=$?
chmod 700 "$SB/roflag/monitor/.state"
assert_eq "an unwritable state dir does NOT wedge the spawn" "$rc" "0"
assert_contains "…and the failure to record is itself announced, not swallowed" \
    "$out" "could NOT record"

# A tree with NO .state dir — a fresh clone, i.e. exactly the old-checkout
# case this guard exists for — must still get a durable row. The gate used to
# be `[ -d <state> ]` with no else, so it silently did not.
mkdir -p "$SB/nostate/monitor"
printf '#!/bin/sh\nexit 79\n' > "$SB/nostate/monitor/assert-gh-wrapped.sh"
chmod +x "$SB/nostate/monitor/assert-gh-wrapped.sh"
cp "$REPO_ROOT/monitor/bash-footgun-patterns.conf" "$SB/nostate/monitor/"
out=$(env NEXUS_ROOT="$SB/nostate" NEXUS_SPAWN_CODE_ROOT="$SB/nostate" \
      NEXUS_WORKER_WINDOW=freshclone bash "$BLOCK" 2>&1); rc=$?
assert_eq "a checkout with no .state still spawns" "$rc" "0"
assert_contains "…and the row is created, not silently dropped" \
    "$(cat "$SB/nostate/monitor/.state/guard-unverified.log" 2>/dev/null)" "freshclone"

# No state dir → still announces, still never wedges.
out=$(env NEXUS_ROOT="$SB/nodir" NEXUS_SPAWN_CODE_ROOT="$SB/sink" bash "$BLOCK" 2>&1); rc=$?
assert_eq "an unwritable/absent state dir does not break the spawn" "$rc" "0"
assert_contains "…and the announcement still reaches stderr" "$out" "NOT CHECKED"

echo
echo "=== 6. The boundary sentence is IN the tree, and does NOT contradict §3 ==="
hdr=$(sed -n '1,45p' "${BASH_SOURCE[0]}")
assert_contains "this suite states the boundary in one sentence" "$hdr" "THE BOUNDARY, in one sentence"
assert_contains "…drawn on guard KIND, not execution path" "$hdr" "SHIM-PRECONDITION guard"
assert_contains "…and names what is NOT closed" "$hdr" "NO OTHER KIND"
# The specific contradiction that forced the redraw: the write-probe is a
# SPAWN-PATH guard and is UNFIXED, so any sentence quantifying over the spawn
# path is false. Assert the sentence no longer makes that claim.
# Scoped to the header — an unscoped grep would match this assertion's own
# pattern and pass for the wrong reason (a self-match, which is its own small
# instance of a check that does not check what it claims).
assert_empty "the sentence no longer quantifies over the SPAWN PATH" \
    "$(grep -c 'guard on the agent-SPAWN path is closed' <<<"$hdr" | grep -v '^0$' || true)"
assert_contains "…and the axis lesson is recorded where the next reader sees it" \
    "$hdr" "the axis the mechanism"

th_summary_and_exit
