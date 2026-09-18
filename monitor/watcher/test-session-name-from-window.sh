#!/usr/bin/env bash
# Pins the session MESSAGING name = tmux window name change
# (your-org/nexus-code#1047) and, more importantly, pins the CAPABILITY GATE
# that keeps it from being catastrophic.
#
# Run: bash monitor/watcher/test-session-name-from-window.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. Cross-session SendMessage addresses a session by its
# name — the name IS the address. The nexus set that name nowhere, so every
# agent self-named `basename($PWD)-<2 hex>`: unpredictable from the window an
# orchestrator can see, and near-identical for two workers in one clone
# (measured: nexus-code-skagentmsg-9b beside -e0). Worse, `orchestrator` — the
# address #1043's worker->orchestrator escalation uses — was only ever a
# hand-typed label, so a respawned orchestrator returned as `nexus-<xx>` and
# escalation failed exactly in the incident where escalation matters.
#
# THE HAZARD THIS SUITE ACTUALLY GUARDS. `--name` is fatal when unsupported:
# `claude --nosuchflag` exits 1 with "error: unknown option". Baking the flag
# in unconditionally would kill every worker spawn AND every orchestrator
# respawn on an older Claude Code pin — taking out the watcher's own recovery
# path to fix a naming nicety. Operators pin and bump Claude Code deliberately
# (skills/nexus.cc-update), so that is a live configuration, not a hypothetical.
# The gate degrades to the derived name, loudly, instead.
#
# NON-VACUITY. "The gate returned 1" proves nothing if the gate can never
# return 0, and "the launcher has no --name" is trivially true of a launcher
# that was never composed. So every mutant below is paired with a control:
#   Control A — the SUPPORTED stub must produce the flag. A gate wired to a
#               constant `false` would pass every mutant and fail here.
#   Control B — the mutant's POTENCY is measured, not assumed: a real
#               `--help`-lacking stub is shown to reject the flag at rc!=0, so
#               the thing the gate prevents is demonstrated to be fatal.
#   Control C — composed launchers are checked with `bash -n`, so a quoting
#               regression that produces a syntactically broken launcher is a
#               FAIL rather than a silently dead pane.
#
# COVERAGE BOUNDARY. This pins the GATE and the COMPOSITION. It does not, and
# cannot here, assert what a live claude writes into ~/.claude/sessions/ —
# that is a property of the claude binary, verified by hand at 2.1.246 and
# recorded on #1047. What this file guarantees is that the repo never emits an
# unconditional --name, and never emits a launcher it cannot parse.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_BIN_SH="$REPO_ROOT/monitor/_claude-bin.sh"

. "$_test_dir/_test_helpers.sh"
PASS=0
FAIL=0
# Counters route through the DURABLE LEDGER (_th_pass/_th_fail), not bare
# arithmetic: `ok`/`bad` are called from the main shell today, but this suite
# is full of `( … )` and `$( … )` fixtures and the next assertion added inside
# one would otherwise increment a counter that dies with the child — a FAILING
# assertion that exits 0. th_summary_and_exit reconciles from the ledger.
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; _th_fail; }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# A stub whose --help ADVERTISES the flag, and one that does not. Both also
# emulate the real client's fatal-unknown-option behaviour so the mutant's
# potency can be measured rather than asserted.
make_stub() { # <path> <advertise:yes|no>
    cat > "$1" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then
    echo "Usage: claude [options]"
    [[ "$2" == "yes" ]] && echo "  -n, --name <name>   Set a display name for this session"
    echo "  --model <model>     Model for the session"
    exit 0
fi
for a in "\$@"; do
    if [[ "\$a" == "--name" && "$2" == "no" ]]; then
        echo "error: unknown option '--name'" >&2; exit 1
    fi
done
exit 0
STUB
    chmod +x "$1"
}
STUB_YES="$WORK/claude-yes"; make_stub "$STUB_YES" yes
STUB_NO="$WORK/claude-no";   make_stub "$STUB_NO"  no

probe() { # <stub> -> prints rc and stderr marker
    ( set +u
      NEXUS_ROOT="$REPO_ROOT" CLAUDE_BIN="$1"
      export NEXUS_ROOT CLAUDE_BIN
      . "$CLAUDE_BIN_SH" >/dev/null 2>&1
      claude_supports_name_flag 2>"$WORK/warn.txt"; echo "rc=$?" )
}

echo '=== 1. Control B: the mutant is POTENT (an unsupported --name IS fatal) ==='
"$STUB_NO" --name whatever >/dev/null 2>"$WORK/e.txt"; rc=$?
[[ $rc -ne 0 ]] && ok "unsupported --name exits non-zero (rc=$rc) — the gate prevents a real death" \
                || bad "unsupported --name was survivable" "rc=$rc; a toothless mutant proves nothing"
grep -q "unknown option" "$WORK/e.txt" \
    && ok "…and says 'unknown option', the real client's wording" \
    || bad "stub did not emulate the real failure" "$(cat "$WORK/e.txt")"

echo '=== 2. Control A: the gate SAYS YES when the flag is advertised ==='
out=$(probe "$STUB_YES")
[[ "$out" == "rc=0" ]] && ok "advertised --name → gate returns 0" \
                       || bad "gate refused a supported claude" "got [$out] — a gate stuck at 'no' passes every mutant below"

echo '=== 3. Mutant A: --help omits --name → gate refuses, LOUDLY ==='
out=$(probe "$STUB_NO")
[[ "$out" == "rc=1" ]] && ok "unadvertised --name → gate returns 1" \
                       || bad "gate accepted an unsupporting claude" "got [$out]"
grep -q "does not support" "$WORK/warn.txt" \
    && ok "…and warns on stderr (a silent omission is the defect class)" \
    || bad "gate degraded SILENTLY" "stderr was: [$(cat "$WORK/warn.txt")]"

echo '=== 4. Mutant B: --help unreadable → gate refuses (fail CLOSED on the flag) ==='
out=$(probe "$WORK/does-not-exist")
[[ "$out" == "rc=1" ]] && ok "unreadable --help → gate returns 1, not a guess" \
                       || bad "gate guessed 'supported' when it could not ask" "got [$out]"
grep -q "could not read" "$WORK/warn.txt" \
    && ok "…and says it could not ask, distinct from 'not supported'" \
    || bad "unreadable --help warned with the wrong reason" "[$(cat "$WORK/warn.txt")]"

echo '=== 5. _respawn_compose_launcher: the orchestrator gets its window name ==='
compose() { # <stub> <target> <outfile>
    ( set +u
      CLAUDE_BIN="$2"; NEXUS_ROOT="$REPO_ROOT"
      export CLAUDE_BIN NEXUS_ROOT
      . "$_test_dir/_respawn.sh" >/dev/null 2>&1
      _respawn_compose_launcher "$3" "$REPO_ROOT" "" "" "$4" ) >/dev/null 2>&1
}
# Assert on the EXEC LINE, never on the whole file: the launcher legitimately
# carries prose, and a comment containing the literal "--name" would satisfy a
# file-wide grep while the FLAG was absent. That is not hypothetical — it is
# exactly the false PASS this suite caught during its own development.
# `grep -m1`, NOT `grep … | head -1`: the piped form makes this an early-exit
# READER, which joins the population early-exit-readers.manifest tracks and
# turns test-early-exit-reader-manifest red (#682). `-m1` stops grep itself, so
# there is no reader and the population is unchanged.
# Matches the claude invocation in EVERY launcher shape. Deliberately not
# anchored on `exec`: the loop-wrapped and --resume heredocs exec claude, but
# the DIRECT worker heredoc does not — anchoring on `exec` silently matched
# nothing there, which is how this fixture first reported "never composed".
# Verified to match exactly ONE non-comment line per composed launcher.
execline() { grep -m1 -E '^[^#]*--dangerously-skip-permissions' "$1"; }
L="$WORK/l.sh"
compose x "$STUB_YES" "$L" orchestrator
case "$(execline "$L")" in
    *"--name orchestrator"*) ok "supported → exec line carries --name orchestrator" ;;
    *) bad "exec line lost the name" "[$(execline "$L")]" ;;
esac
bash -n "$L" && ok "…and the composed launcher parses (Control C)" \
             || bad "composed launcher is not valid bash" "see $L"

echo '=== 6. Mutant A at the launcher: no flag, and still a WORKING launcher ==='
L2="$WORK/l2.sh"
compose x "$STUB_NO" "$L2" orchestrator
case "$(execline "$L2")" in
    *"--name"*) bad "unsupporting claude still got --name" "this is the dead-orchestrator branch" ;;
    "")         bad "no exec line at all" "degrading must not remove the exec" ;;
    *)          ok "unsupported → exec line omits --name entirely" ;;
esac
[[ -n "$(execline "$L2")" ]] \
    && ok "…and still execs claude (degrades to derived name, not to no orchestrator)" \
    || bad "launcher lost its exec line" "$(cat "$L2")"
bash -n "$L2" && ok "…and parses (Control C)" || bad "degraded launcher is not valid bash" "see $L2"

echo '=== 7. Quoting: an operator-supplied window name cannot break the launcher ==='
L3="$WORK/l3.sh"
compose x "$STUB_YES" "$L3" 'weird name $(touch '"$WORK"'/pwned) x'
bash -n "$L3" && ok "hostile window name still yields parseable bash" \
              || bad "hostile window name broke the launcher" "see $L3"
[[ -e "$WORK/pwned" ]] && bad "command substitution in a window name EXECUTED" "at compose time" \
                       || ok "…and no command substitution fired at compose time"

echo '=== 8. The SCOPE sentence is present in the source (the brief required it) ==='
for f in monitor/claude-loop.sh monitor/spawn-worker.sh monitor/watcher/_respawn.sh; do
    if grep -q "rename-window" "$REPO_ROOT/$f"; then
        ok "$f states the live-agent-vs-task-key limit"
    else
        bad "$f dropped the scope sentence" "a reader will treat the name as a durable task key"
    fi
done

echo '=== 9. Every --name emission is behind the capability gate ==='
# A line-based grep cannot see an enclosing `if`, so this checks PROXIMITY:
# a literal `--name "$VAR"` must have the gate call within the 3 preceding
# lines. Spawn-worker and _respawn emit a pre-gated ${NAME_ARG}/${name_flag}
# instead and so have no literal site at all; claude-loop's site sits directly
# inside `if [[ -n "$WINDOW" ]] && claude_supports_name_flag`.
ungated=0
for f in monitor/spawn-worker.sh monitor/watcher/_respawn.sh monitor/claude-loop.sh; do
    while IFS= read -r hit; do
        printf '    UNGATED: %s:%s\n' "$f" "$hit"; ungated=$(( ungated + 1 ))
    done < <(awk '
        /^[[:space:]]*#/ { for(i=3;i>=1;i--) prev[i+1]=prev[i]; prev[1]=$0; next }
        /--name "\$(WINDOW_NAME|target_window|WINDOW)"/ ||
        /--name "\$WINDOW"/ || /--name "\$WINDOW_NAME"/ || /--name "\$target_window"/ {
            gated=0
            if ($0 ~ /claude_supports_name_flag/) gated=1
            for (i=1;i<=3;i++) if (prev[i] ~ /claude_supports_name_flag/) gated=1
            if (!gated) print NR": "$0
        }
        { for(i=3;i>=1;i--) prev[i+1]=prev[i]; prev[1]=$0 }
    ' "$REPO_ROOT/$f")
done
[[ $ungated -eq 0 ]] && ok "every literal --name site is behind the capability gate" \
                     || bad "$ungated ungated --name site(s)" "these die on an older claude pin"

# Non-vacuity for the lint itself: it must FIRE on a planted offender,
# otherwise "0 ungated sites" is indistinguishable from a broken matcher.
PLANT="$WORK/plant.sh"
printf '%s\n' '#!/bin/bash' 'args+=( --name "$WINDOW" )' > "$PLANT"
planted=$(awk '
    /^[[:space:]]*#/ { for(i=3;i>=1;i--) prev[i+1]=prev[i]; prev[1]=$0; next }
    /--name "\$WINDOW"/ {
        gated=0
        if ($0 ~ /claude_supports_name_flag/) gated=1
        for (i=1;i<=3;i++) if (prev[i] ~ /claude_supports_name_flag/) gated=1
        if (!gated) print NR
    }
    { for(i=3;i>=1;i--) prev[i+1]=prev[i]; prev[1]=$0 }
' "$PLANT" | wc -l)
[[ "$planted" -eq 1 ]] && ok "…and the lint FIRES on a planted ungated site (it has teeth)" \
                       || bad "lint is blind" "planted offender produced $planted hits, want 1"

echo '=== 10. F2: the WORKER path is POSITIVELY asserted (both launcher shapes) ==='
# WHY THIS SECTION EXISTS. Without it, spawn-worker's two call sites had NO
# assertion at all: test-spawn-worker.sh's shared stub `claude` does not answer
# --help, so the gate declines for that whole suite and NAME_ARG is always
# empty. Deleting both ${NAME_ARG:+ …} interpolations left every suite green —
# the change SURVIVED ITS OWN DELETION. A fixture whose stub ADVERTISES the
# flag is the only thing that can tell "working" from "absent".
make_fake_nexus() { # <root> <spawn-worker source file> <advertise:yes|no>
    local root="$1" sw="$2" adv="$3"
    mkdir -p "$root/monitor" "$root/skills/nexus.worker-defaults" "$root/reports" \
             "$root/node_modules/.bin"
    cp "$sw" "$root/monitor/spawn-worker.sh"; chmod +x "$root/monitor/spawn-worker.sh"
    # The guard-block template, installed BY NAME and on its own line
    # (your-org/nexus-code#1094). The loop below already copies it — measured,
    # the file really does land in the fixture — but
    # `test-guard-closure-boundary.sh`'s "every fixture installing
    # spawn-worker.sh installs the template" detector is a STATIC, position-
    # anchored match on a literal `cp … guard-block.sh.in`, and here the literal
    # sits in a `for` list while the `cp` carries only `"$f"`. So it reported
    # this fixture MISSING — a false RED, and precisely the residual that
    # detector's own comment declares ("a `cp` reached by a route none of those
    # positions describe … no such fixture exists today"). One does now.
    #
    # Closing the INSTANCE rather than widening the PREDICATE is deliberate. The
    # predicate was tightened from a mention test to an install test on purpose,
    # after a measured incident in which deleting only the `cp` line left the
    # explanatory comment alive and the manifest green; teaching it to accept a
    # variable argument re-opens exactly that hole. Every sibling fixture
    # already installs the template this way — this was the lone outlier.
    cp "$REPO_ROOT/monitor/guard-block.sh.in" "$root/monitor/guard-block.sh.in"
    local f
    for f in _claude-bin.sh _tmux-window.sh _fm_lib.sh _bookkeeping.sh \
             guard-block.sh.in request-channel.sh _channel_lib.sh \
             worker-settings.json; do
        [[ -e "$REPO_ROOT/monitor/$f" ]] && cp "$REPO_ROOT/monitor/$f" "$root/monitor/$f"
    done
    chmod +x "$root/monitor/request-channel.sh" 2>/dev/null || true
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$root/monitor/ng"; chmod +x "$root/monitor/ng"
    # The project-local claude _claude-bin.sh resolves FIRST — this is the
    # binary the gate interrogates, so its --help is what decides the branch.
    make_stub "$root/node_modules/.bin/claude" "$adv"
    printf '## Worker floor\n\nfloor body\n' > "$root/skills/nexus.worker-defaults/SKILL.md"
}
STUB_BIN="$WORK/stubbin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<'TMUXSTUB'
#!/bin/bash
case "$1" in
    new-window) echo '@7'; exit 0 ;;
    *) exit 0 ;;
esac
TMUXSTUB
chmod +x "$STUB_BIN/tmux"

SPAWN_TMP="$WORK/spawn-tmp"; mkdir -p "$SPAWN_TMP"

# <root> <window> <extra args...> -> echoes the composed launcher's exec line
spawn_execline() {
    local root="$1" win="$2"; shift 2
    local pf="$WORK/prompt.md"; printf 'probe prompt\n' > "$pf"
    ( cd "$root" && TMPDIR="$SPAWN_TMP" PATH="$STUB_BIN:$PATH" NEXUS_ROOT="$root" \
        ./monitor/spawn-worker.sh -n "$win" -c "$root" -p "$pf" "$@" ) >/dev/null 2>&1
    local g=( "$SPAWN_TMP"/spawn-launcher-"$win".*.sh )
    [[ -e "${g[0]}" ]] || { printf ''; return; }
    execline "${g[0]}"
}

FN_YES="$WORK/fn-yes"
make_fake_nexus "$FN_YES" "$REPO_ROOT/monitor/spawn-worker.sh" yes
direct_line=$(spawn_execline "$FN_YES" nameflag-direct)
if [[ -z "$direct_line" ]]; then
    bad "direct-shape launcher was never composed" "fixture broken — no assertion is being made"
    bad "direct-shape launcher parse" "not composed"
else
    case "$direct_line" in
        *"--name nameflag-direct"*) ok "DIRECT shape: exec line carries --name nameflag-direct" ;;
        *) bad "DIRECT shape lost --name" "[$direct_line]" ;;
    esac
    g=( "$SPAWN_TMP"/spawn-launcher-nameflag-direct.*.sh )
    bash -n "${g[0]}" && ok "…and the direct launcher parses" \
                      || bad "direct launcher is not valid bash" "see ${g[0]}"
fi

# --resume shape: a second, independent call site that the direct-shape
# assertion above does not cover (it composes its own launcher heredoc, and
# $WINDOW_NAME is not final there until it falls back to $RESUME_TARGET —
# which is exactly why NAME_ARG is computed per compose site, not once).
# Contract: `-p` is INVALID here and `-n` is required, so this cannot reuse
# spawn_execline. $HOME is redirected into $WORK so the fixture transcript
# never touches the operator's real ~/.claude/projects.
RSID="11111111-2222-3333-4444-555555555555"
RSLUG=$(printf '%s' "$FN_YES" | sed 's|[^a-zA-Z0-9]|-|g')
mkdir -p "$WORK/home/.claude/projects/$RSLUG"
printf '{}\n' > "$WORK/home/.claude/projects/$RSLUG/$RSID.jsonl"
( cd "$FN_YES" && HOME="$WORK/home" TMPDIR="$SPAWN_TMP" PATH="$STUB_BIN:$PATH" \
    NEXUS_ROOT="$FN_YES" ./monitor/spawn-worker.sh \
    --resume "$RSID" -n nameflag-resume -c "$FN_YES" ) >/dev/null 2>&1
_rg=( "$SPAWN_TMP"/spawn-launcher-nameflag-resume.*.sh )
resume_line=''
[[ -e "${_rg[0]}" ]] && resume_line=$(execline "${_rg[0]}")
if [[ -z "$resume_line" ]]; then
    bad "resume-shape launcher was never composed" "fixture broken — no assertion is being made"
    bad "resume-shape launcher parse" "not composed"
else
    case "$resume_line" in
        *"--name nameflag-resume"*) ok "RESUME shape: exec line carries --name nameflag-resume" ;;
        *) bad "RESUME shape lost --name" "[$resume_line]" ;;
    esac
    g=( "$SPAWN_TMP"/spawn-launcher-nameflag-resume.*.sh )
    bash -n "${g[0]}" && ok "…and the resume launcher parses" \
                      || bad "resume launcher is not valid bash" "see ${g[0]}"
fi

echo '=== 11. F3: when the gate DECLINES, the launcher is byte-identical to pre-#1047 ==='
# The other half of the potency argument. §6 shows the "yes" branch works; this
# shows the "no" branch is INERT — not merely that it omits the flag, but that
# it reproduces the pre-change line exactly, so a declining gate cannot perturb
# spacing, quoting or token order for operators on an older pin.
# ── WHERE THE "PRE-#1047" SOURCE COMES FROM, AND WHY NOT origin/dev ──
# This block used to lift $PRE from `origin/dev` and gate it with
# `grep -q -- '--name'`. `origin/dev` is a MOVING REF: once #1047 merged, its
# spawn-worker.sh carried --name, the gate fired, and this suite has been RED on
# `dev` ever since (your-org/nexus-code#1094). The gate was RIGHT — both sides
# were post-#1047 and the byte-identity below was comparing the current source
# against itself, passing for no reason. What had gone stale is the ANCHOR.
#
# Same class, same week, same remedy as `test-pane-state-claude-identity.sh`'s
# #908 control and `test-tmux-shim.sh`'s pre-fix copy: a chain of candidate refs
# preferring real historical code, each GATED, then a SYNTHESIZED fallback —
# because the git lookup expires. After one more merge every reachable ref
# carries the fix, and a control that skips from then on is a gap reopened
# permanently.
#
# THE GATE IS BEHAVIOURAL, NOT TEXTUAL, and that is forced rather than stylish.
# `grep -q -- '--name'` over the FILE cannot work for the synthesis: the string
# survives in `_spawn_name_arg`'s own body and in its comments, so a correctly
# synthesized pre-#1047 source would be rejected by it. The property is not
# "the file never says --name", it is "this source does not PUT --name on the
# exec line even when the capability gate says yes". So each candidate is built
# into a fake nexus with the ADVERTISING stub and its composed exec line is
# read. A post-#1047 source emits the flag there and is rejected; a genuine
# pre-#1047 source cannot.
#
# Note this gate is deliberately NOT the assertion. Selecting a candidate on
# "it produces no --name when declining" and then asserting the same thing
# would pass by construction. The gate asks about the ACCEPTING branch; the
# assertion below is about the DECLINING one.
_pre1047_ok() {   # <spawn-worker source> -> 0 if it emits no --name when the gate SAYS YES
    local src="$1" probe="$WORK/fn-gate$RANDOM"
    make_fake_nexus "$probe" "$src" yes || return 1
    local line; line=$(spawn_execline "$probe" "gateprobe$RANDOM")
    [[ -n "$line" ]] || return 1          # composed nothing: cannot vouch either way
    [[ "$line" != *"--name"* ]]
}
PRE="$WORK/spawn-worker-pre1047.sh"
_PRE_PROV=""
for _ref in "$(git -C "$REPO_ROOT" merge-base origin/dev HEAD 2>/dev/null)" origin/dev HEAD~1; do
    [[ -n "$_ref" ]] || continue
    git -C "$REPO_ROOT" show "${_ref}:monitor/spawn-worker.sh" > "$PRE" 2>/dev/null || continue
    [[ -s "$PRE" ]] || continue
    if _pre1047_ok "$PRE"; then _PRE_PROV="git:${_ref}"; break; fi
done
if [[ -z "$_PRE_PROV" ]]; then
    # SYNTHESIZE. #1047's entire footprint on the composed line is the two
    # `${NAME_ARG:+ $NAME_ARG}` interpolations; removing them reproduces the
    # pre-#1047 line exactly, and does so at any depth of checkout.
    sed 's/\${NAME_ARG:+ \$NAME_ARG}//g' \
        "$REPO_ROOT/monitor/spawn-worker.sh" > "$PRE"
    # A MUTANT MUST PROVE IT APPLIED — a drifted sed leaves the file identical
    # and the comparison silently becomes source-against-itself, which is the
    # exact vacuity this block exists to prevent. Three checks: something
    # changed, it still parses, and it passes the behavioural gate.
    if [[ -s "$PRE" ]] && ! cmp -s "$PRE" "$REPO_ROOT/monitor/spawn-worker.sh" \
       && bash -n "$PRE" 2>/dev/null && _pre1047_ok "$PRE"; then
        _PRE_PROV="synthesized"
    fi
fi
if [[ -n "$_PRE_PROV" ]]; then
    ok "control [$_PRE_PROV]: the pre-#1047 source emits no --name even when the gate says YES"
    FN_NO="$WORK/fn-no";  make_fake_nexus "$FN_NO"  "$REPO_ROOT/monitor/spawn-worker.sh" no
    FN_PRE="$WORK/fn-pre"; make_fake_nexus "$FN_PRE" "$PRE" no
    now_line=$(spawn_execline "$FN_NO"  declined-win)
    pre_line=$(spawn_execline "$FN_PRE" declined-win2)
    # Normalise only the window name, which legitimately differs between the
    # two runs; everything else must match byte for byte.
    now_norm=${now_line//declined-win/W}; pre_norm=${pre_line//declined-win2/W}
    now_norm=${now_norm//$FN_NO/R};       pre_norm=${pre_norm//$FN_PRE/R}
    # …and the per-spawn RANDOM session-id, which differs between any two runs
    # of the same source and is not what this assertion is about.
    _uuid='[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}'
    now_norm=$(printf '%s' "$now_norm" | sed "s/$_uuid/SID/g")
    pre_norm=$(printf '%s' "$pre_norm" | sed "s/$_uuid/SID/g")
    if [[ -z "$now_line" || -z "$pre_line" ]]; then
        bad "declined byte-identity" "one side composed nothing (now=[$now_line] pre=[$pre_line])"
    elif [[ "$now_norm" == "$pre_norm" ]]; then
        ok "declined exec line is byte-identical to pre-#1047"
    else
        bad "declined exec line DIFFERS from pre-#1047" "now=[$now_norm] pre=[$pre_norm]"
    fi
else
    # FAIL, not skip — the ONE disposition rule for every control of this shape
    # (your-org/nexus-code#1094, #1100; the reasoning is written out once, at
    # test-pane-state-claude-identity.sh's matching branch). In short: SKIP is
    # for an ENVIRONMENTAL precondition; the synthesis needs no history, refs or
    # network, so the only remaining route here is a drifted sed — a defect in
    # this suite, and a defect must be red. The message says where to look
    # rather than blaming fetch-depth, which would send the next reader to the
    # wrong place.
    bad "no pre-#1047 source could be obtained" "every candidate ref already emits --name AND the synthesis did not apply (its sed pattern has probably drifted from the \${NAME_ARG:+ …} interpolations in monitor/spawn-worker.sh)"
    bad "declined byte-identity" "control unavailable"
fi

echo '=== 12. claude-loop.sh: the THIRD worker call site, asserted end-to-end ==='
# Same class as §10. claude-loop.sh is the loop-wrapped shape
# (monitor.retain.use_loop_wrapper) and passes --name on the first call AND on
# every --continue respawn. Nothing else in the repo asserts it, so without
# this it too would survive its own deletion. This runs the REAL script against
# a stub claude that records its argv, so it measures what claude is actually
# invoked with rather than what the source appears to say.
loop_argv() { # <advertise:yes|no> -> the argv the stub claude saw
    # Two statements, not `local adv=$1 root=...$adv`: bash expands every
    # operand of `local` BEFORE assigning any, so the second would read an
    # unset $adv and abort under `set -u`.
    local adv="$1"
    local root="$WORK/loop-$adv"
    mkdir -p "$root/monitor" "$root/node_modules/.bin"
    cp "$REPO_ROOT/monitor/_claude-bin.sh" "$root/monitor/_claude-bin.sh"
    cat > "$root/node_modules/.bin/claude" <<LOOPSTUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then
    echo "Usage: claude [options]"
    [[ "$adv" == "yes" ]] && echo "  -n, --name <name>   Set a display name for this session"
    exit 0
fi
printf '%s\n' "ARGV: \$*" >> "$root/argv.log"
exit 0
LOOPSTUB
    chmod +x "$root/node_modules/.bin/claude"
    printf 'hello\n' > "$root/prompt.md"; : > "$root/argv.log"
    # --max-restarts 0 plus the absent retain event stop the loop after one
    # run (documented exit 10), so this cannot spin.
    timeout 60 env NEXUS_ROOT="$root" STATE_DIR="$root/state" \
        bash "$REPO_ROOT/monitor/claude-loop.sh" \
        --window loopwin --prompt-file "$root/prompt.md" --max-restarts 0 \
        >/dev/null 2>&1
    cat "$root/argv.log" 2>/dev/null
}
loop_yes=$(loop_argv yes)
case "$loop_yes" in
    *"--name loopwin"*) ok "LOOP shape: claude is invoked with --name loopwin" ;;
    "") bad "loop fixture ran no claude at all" "argv log empty — no assertion is being made" ;;
    *)  bad "LOOP shape lost --name" "[$loop_yes]" ;;
esac
loop_no=$(loop_argv no)
case "$loop_no" in
    *"--name"*) bad "LOOP shape passed --name to a claude that rejects it" "[$loop_no]" ;;
    "") bad "declining loop fixture ran no claude at all" "argv log empty" ;;
    *)  ok "…and omits it entirely when the gate declines (claude still runs)" ;;
esac

echo '=== 13. #1289: the --help probe is BOUNDED, and a timeout is DISTINGUISHABLE ==='
# `claude_supports_name_flag` runs `"$CLAUDE_BIN" --help` with no bound. That
# call is on the watcher's orchestrator-respawn path (`_respawn.sh:716-717`,
# inside `_respawn_compose_launcher`, called at `:1173` immediately before
# `_respawn_spawn_window` at `:1176`) and the whole dance runs under the async
# in-flight guard (`_target_absent.sh:159-162`). A hang there holds the guard,
# the orchestrator stays dead, and the watcher logs the reassuring
# `respawn-agent (async): launch deferred (in flight)` on every poll — forever.
#
# `timeout` INJECTS a status outside the callee's vocabulary (#1248): 124 on
# TERM, 137 on KILL after `-k`. Both must read as TIMED OUT, never as "the
# binary answered and said no" and never as "the binary failed to run" — three
# outcomes with three different remedies.
_slow="$WORK/claude-slow"
cat > "$_slow" <<'SLOWSTUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then sleep 30; echo "  -n, --name <name>  x"; exit 0; fi
exit 0
SLOWSTUB
chmod +x "$_slow"
_broken="$WORK/claude-broken"
printf '#!/usr/bin/env bash\nexit 3\n' > "$_broken"; chmod +x "$_broken"

# probe_b <stub> <bound-seconds> [timeout-bin-seam] -> prints "rc=N"; stderr to warn.txt
# The seam is passed with ${N-…} not ${N:-…}: an EMPTY seam is the whole point
# (it is how the `timeout`-absent path is reached), and `:-` would swallow it.
probe_b() {
    local _stub="$1" _bound="$2" _seam="${3-__NOSEAM__}"
    ( set +u
      NEXUS_ROOT="$REPO_ROOT"; CLAUDE_BIN="$_stub"; NEXUS_CLAUDE_HELP_TIMEOUT="$_bound"
      export NEXUS_ROOT CLAUDE_BIN NEXUS_CLAUDE_HELP_TIMEOUT
      if [[ "$_seam" != "__NOSEAM__" ]]; then
          NEXUS_CLAUDE_HELP_TIMEOUT_BIN="$_seam"; export NEXUS_CLAUDE_HELP_TIMEOUT_BIN
      fi
      . "$CLAUDE_BIN_SH" >/dev/null 2>&1
      claude_supports_name_flag 2>"$WORK/warn.txt"; echo "rc=$?" )
}

# PRECONDITION. Without a `timeout` binary every assertion below would pass
# for the wrong reason (the probe would simply be unbounded and the slow stub
# would take 30 s, which the elapsed assertion — and only that one — would
# catch). Establish it rather than assume it.
_tbin=$( ( set +u; NEXUS_ROOT="$REPO_ROOT"; CLAUDE_BIN="$STUB_YES"; export NEXUS_ROOT CLAUDE_BIN
           . "$CLAUDE_BIN_SH" >/dev/null 2>&1; printf '%s' "${_CLAUDE_TIMEOUT_BIN:-}" ) )
[[ -n "$_tbin" ]] && ok "PRECONDITION: a timeout binary is resolved ($_tbin)" \
                  || bad "no timeout binary resolved" "the bound cannot fire; every assertion below is vacuous"

# LIVE CONTROL. Bounding must not break the happy path — a probe stuck at
# "no" would satisfy every refusal assertion below without doing anything.
[[ "$(probe_b "$STUB_YES" 10)" == "rc=0" ]] \
    && ok "LIVE CONTROL: a fast, advertising claude still returns 0 under the bound" \
    || bad "the bound broke the supported path" "got [$(probe_b "$STUB_YES" 10)]"

# THE BOUND ACTUALLY FIRES. The elapsed assertion is the load-bearing one:
# without it an unbounded probe would ALSO return rc=1 (eventually), so rc
# alone cannot distinguish "bounded" from "waited 30 s and gave up".
_t0=$(date +%s)
_slow_rc=$(probe_b "$_slow" 1)
_t1=$(date +%s)
_elapsed=$(( _t1 - _t0 ))
[[ "$_slow_rc" == "rc=1" ]] && ok "a --help that never returns → gate returns 1" \
                            || bad "slow --help did not refuse" "got [$_slow_rc]"
(( _elapsed <= 8 )) \
    && ok "…and it returned in ${_elapsed}s against a 30s stub — the BOUND fired, not patience" \
    || bad "the probe was not bounded" "took ${_elapsed}s; the stub sleeps 30s, the bound was 1s"
grep -q "TIMED OUT" "$WORK/warn.txt" \
    && ok "…and says TIMED OUT (rc 124/137 is injected, not claude's own — #1248)" \
    || bad "a timeout was not named as one" "[$(cat "$WORK/warn.txt")]"
# The three outcomes must not collapse into each other.
grep -q "does not support" "$WORK/warn.txt" \
    && bad "a TIMEOUT was reported as 'does not support'" "that is a claim about the binary it never made" \
    || ok "…and does NOT claim the binary said no"

# "could not read" (binary ran and failed) stays DISTINCT from "TIMED OUT".
_brk_rc=$(probe_b "$_broken" 10)
[[ "$_brk_rc" == "rc=1" ]] && ok "a binary that exits non-zero with no output → gate returns 1" \
                           || bad "broken binary did not refuse" "got [$_brk_rc]"
grep -q "could not read" "$WORK/warn.txt" \
    && ok "…and says 'could not read', not 'TIMED OUT'" \
    || bad "broken-binary diagnostic wrong" "[$(cat "$WORK/warn.txt")]"
grep -q "TIMED OUT" "$WORK/warn.txt" \
    && bad "a plain failure was reported as a TIMEOUT" "the two have different remedies" \
    || ok "…and the two diagnostics do not collapse into each other"

# THE UNBOUNDED PATH IS LOUD. A host with no `timeout` reinstates the #1289
# wedge; that must be said, not silently tolerated. Reached via the seam.
[[ "$(probe_b "$STUB_YES" 10 "")" == "rc=0" ]] \
    && ok "no timeout binary → the probe still works (degrades, never refuses to spawn)" \
    || bad "the timeout-absent path broke the probe" "got [$(probe_b "$STUB_YES" 10 "")]"
grep -q "UNBOUNDED" "$WORK/warn.txt" \
    && ok "…and warns that the probe is UNBOUNDED (a missing bound is not a silent state)" \
    || bad "timeout-absent degraded silently" "[$(cat "$WORK/warn.txt")]"

# `--foreground` MUST NOT appear. Measured on this host against a stub whose
# --help spawns a child: plain `timeout` returns in 1005 ms, `--foreground` in
# 30014 ms — the orphaned grandchild holds the command substitution's pipe
# open, so the bound becomes decorative WHILE STILL REPORTING rc 124. A guard
# here because it is a plausible "improvement" that silently restores #1289.
# NON-COMMENT LINES ONLY. The file-wide form FAILED here on first run: the
# helper's own "DO NOT ADD --foreground" comment satisfies a whole-file grep,
# so the guard reddened on the very prose explaining it. That is this suite's
# own rule at the `execline` helper above ("assert on the EXEC LINE, never on
# the whole file") arriving one section later, and it cuts BOTH ways — a
# comment can redden a guard that should be green, and it can green a guard
# that should be red.
_fg=$(awk '!/^[[:space:]]*#/' "$CLAUDE_BIN_SH" | grep -c -- '--foreground')
# POSITIVE CONTROL for the scoping itself: the same non-comment extraction MUST
# still see the invocation it is scoping over, or a zero above means only "the
# awk matched nothing".
_probe_line=$(awk '!/^[[:space:]]*#/' "$CLAUDE_BIN_SH" | grep -c -- '--help')
[[ "$_probe_line" -ge 1 ]] \
    && ok "POSITIVE CONTROL: the non-comment extraction still sees the --help invocation" \
    || bad "the non-comment extraction sees no --help call at all" "the --foreground guard below is vacuous"
[[ "$_fg" == "0" ]] \
    && ok "the probe does not pass --foreground (it would orphan the child and un-bound the wait)" \
    || bad "--foreground appeared in the probe" "it reports rc 124 while still waiting for the grandchild"

# EXACT count guard, per section. A floor ("at least N") would let a fixture
# that silently stopped composing launchers pass by asserting less; this pins
# the number so a skipped section is a FAILURE, not a smaller green.
EXPECTED=$(( 2 + 1 + 2 + 2 + 2 + 3 + 2 + 3 + 2 + 4 + 2 + 2 + 13 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
