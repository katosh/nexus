#!/usr/bin/env bash
# monitor/watcher/test-worker-floor-content.sh
#
# The `## Worker floor` of skills/nexus.worker-defaults/SKILL.md is injected
# verbatim into EVERY spawn prompt by monitor/spawn-worker.sh, so it is the
# only surface that reaches every worker regardless of brief. Two rules were
# put there because their absence cost real hours, and a rule that lives only
# in an issue is not a rule (your-org/nexus-code#1446, #1422):
#
#   * never `| head` an existence query over a large tree; never recurse
#     into `reports/`; anything long goes through async-run.sh (three workers
#     wedged >5h in one session, every pane reading working-background);
#   * `/tmp/c71780` holds SOCKETS ONLY (16.5 GiB of worker payload landed
#     there because briefs handed it out as scratch).
#
# This suite pins that the floor carries them and — the half that makes it a
# test rather than a grep — that spawn-worker.sh's own injection delivers them
# into a composed prompt, driven with the REAL skill file. A potency control
# shows the assertion can fail: a floor with the rule removed is caught.

set -u
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad()  { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
skip() { printf '  SKIP: %s\n' "$1"; SKIP=$(( SKIP + 1 )); }

SKILL="$_repo_root/skills/nexus.worker-defaults/SKILL.md"
floor=$(awk '/^## Worker floor[[:space:]]*$/{f=1;next} f && /^## /{exit} f' "$SKILL")
[[ -n "$floor" ]] || { echo "could not extract ## Worker floor from $SKILL" >&2; exit 1; }

echo "=== the floor carries the #1446 and #1422 rules ==="
must=(
  'Never `| head` an existence query'
  'monitor/ng report-grep'
  'async-run.sh'
  '/tmp/c71780` holds SOCKETS ONLY'
  'bg_wedged=1'
  # your-org/nexus-code#1523: a retained rc is not an armed wake. The floor
  # must NAME what re-invokes a parked agent (run_in_background / Monitor) and
  # say that async-run.sh does not — measured: rc 4 retained, 809 s idle.
  'A retained exit status is not an armed wake'
  'run_in_background'
)
for m in "${must[@]}"; do
    if grep -qF -- "$m" <<<"$floor"; then ok "floor states: $m"; else bad "floor is missing: $m"; fi
done

echo "=== the injected prompt carries them (real skill file through spawn-worker.sh --print-prompt) ==="
# NEXUS_ALLOW_SECONDARY_ROOT=1: a clone under <primary>/work/ is re-rooted to
# the PRIMARY by default (#577), which would read the primary's skill file
# rather than this tree's — the floor under test.
#
# A `claude` STUB (your-org/nexus-code#1449 skeptic, blocker): spawn-worker.sh
# resolves $CLAUDE_BIN through _claude-bin.sh BEFORE it composes the prompt and
# refuses with "no claude binary found" when none exists — which is every CI
# runner. The first cut of this suite ran without one, hid that refusal behind
# `2>/dev/null`, and read the empty output as "cannot assert": green on a
# workstation that HAS a claude, red on every runner that does not (#1445
# inverted). The stub is the same shape test-spawn-worker-reply-to.sh installs.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"
printf 'task body for the floor test\n' > "$T/prompt.md"
# stderr is KEPT: the injector's own diagnostic is the reason when it refuses,
# and a suite that swallows it reports "cannot assert" where the truth is
# "could not run" — the silence-as-absence class, inside a suite written to
# catch it.
prompt=$(cd "$_repo_root" && NEXUS_ROOT="$_repo_root" NEXUS_ALLOW_SECONDARY_ROOT=1 CLAUDE_BIN="$T/bin/claude" \
         bash monitor/spawn-worker.sh -n floorct -c "$T" -p "$T/prompt.md" --print-prompt 2>"$T/injector.err"); prompt_rc=$?
# THE SKIP HAS EXACTLY ONE LEGITIMATE TRIGGER (w221sk, round 3): the injector
# had no `claude` binary to resolve. Every OTHER non-zero rc or empty output —
# a missing floor file (spawn-worker's own exit 2, the exact wiring this suite
# exists to test), a bad prompt path, anything — is a REAL failure and must
# print the injector's line and go RED. The first cut skipped on the SHAPE of
# the failure (`rc != 0 || empty`), which converted a regression into silence:
# measured, a missing floor read 6 passed / 0 failed / 1 skipped, rc 0, GREEN.
# A suite that skips leaves the population; a red at least is loud.
_injector_verdict() {   # <rc> <stdout> <stderr-file> -> skip | fail | ok
    local rc="$1" out="$2" errf="$3"
    if grep -qF 'no claude binary found' "$errf" 2>/dev/null; then printf 'skip'
    elif (( rc != 0 )) || [[ -z "$out" ]]; then printf 'fail'
    else printf 'ok'; fi
}
case "$(_injector_verdict "$prompt_rc" "$prompt" "$T/injector.err")" in
    skip) skip "injection block: no claude binary for spawn-worker.sh to resolve (rc $prompt_rc): $(sed -n 1p "$T/injector.err" 2>/dev/null)" ;;
    fail) bad "spawn-worker.sh --print-prompt FAILED (rc $prompt_rc, $(wc -c <<<"$prompt") B): $(sed -n 1p "$T/injector.err" 2>/dev/null)" ;;
esac
if [[ "$(_injector_verdict "$prompt_rc" "$prompt" "$T/injector.err")" != ok ]]; then
    :
elif grep -qF 'task body for the floor test' <<<"$prompt"; then
    ok "spawn-worker.sh --print-prompt composed a prompt (positive control: the task body is in it)"
    for m in 'Never `| head` an existence query' 'SOCKETS ONLY' 'A retained exit status is not an armed wake'; do
        if grep -qF -- "$m" <<<"$prompt"; then ok "injected prompt carries: $m"; else bad "injected prompt lacks: $m"; fi
    done
else
    bad "spawn-worker.sh --print-prompt ran (rc 0) but the composed prompt lacks the task body — injection cannot be attributed: $(sed -n 1p "$T/injector.err" 2>/dev/null)"
fi

echo "=== potency: the injector verdict skips on ONE reason and fails on every other ==="
printf 'spawn-worker: _claude-bin.sh: no claude binary found\n' > "$T/e1"
printf 'spawn-worker: floor file missing: /x/skills/nexus.worker-defaults/SKILL.md\n' > "$T/e2"
: > "$T/e3"
[[ "$(_injector_verdict 1 "" "$T/e1")" == skip ]] && ok "no claude binary → skip (the only legitimate skip)" || bad "no-claude case not classified skip"
[[ "$(_injector_verdict 2 "" "$T/e2")" == fail ]] && ok "a missing floor file (rc 2) → FAIL, not skip" || bad "missing-floor case was classified $(_injector_verdict 2 "" "$T/e2")"
[[ "$(_injector_verdict 0 "" "$T/e3")" == fail ]] && ok "rc 0 with EMPTY output → FAIL, not skip" || bad "empty-output case was classified $(_injector_verdict 0 "" "$T/e3")"
[[ "$(_injector_verdict 0 "some prompt" "$T/e3")" == ok ]] && ok "rc 0 with output → ok (control)" || bad "healthy case misclassified"

echo "=== potency: a floor with the rule removed is caught ==="
stripped=$(grep -vF 'Never `| head` an existence query' <<<"$floor")
if grep -qF 'Never `| head` an existence query' <<<"$stripped"; then
    bad "POTENCY: the stripped floor still matches — the assertion cannot fail"
else
    ok "POTENCY: with the #1446 line removed the floor assertion would go red"
fi
stripped=$(grep -vF 'A retained exit status is not an armed wake' <<<"$floor")
if grep -qF 'A retained exit status is not an armed wake' <<<"$stripped"; then
    bad "POTENCY: the wake-stripped floor still matches — the #1523 assertion cannot fail"
else
    ok "POTENCY: with the #1523 wake line removed the floor assertion would go red"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ($SKIP skipped — NOT covered) ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
