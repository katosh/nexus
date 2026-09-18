#!/usr/bin/env bash
# test-auth-hold.sh — your-org/nexus-code#1518.
#
# The watcher must not paste an emit INTO the operator's `/login` dialog (the
# paste's trailing Enter ANSWERS the dialog and selects a login method — the
# `#1200` hazard, on the one paste path `#1200` did not reach), and must not be
# silenced for ever by a login nobody finishes.
#
# SEVEN PARTS, one per thing that can independently rot. Each is stated with the
# failure it exists to catch, because a part whose failure nobody can name is a
# part that will be deleted the first time it is inconvenient.
#
#   A  DETECTOR, against the REAL captures. The committed fixtures were taken
#      from the real claude binary at 2.1.268 through `monitor/cc-harness`
#      against the auth-free mock backend — no real `/login`, no credentials, no
#      egress. Carries NEGATIVE CONTROLS: a plain idle pane, a workspace-trust
#      dialog and an unnamed dialog must NOT grow an `auth=` field, or the hold
#      engages on a healthy board.
#
#   B  THE POSITIVE CONTROL THE TASK ASKS FOR: an UNRECOGNISED login surface
#      must not read as "no login". This is the part that makes the safe-failure
#      claim in `pane-state.sh`'s header EXECUTABLE rather than asserted — it
#      plants a login dialog with every one of the three recognised strings
#      REWORDED and requires `state=blocked` to survive, because `blocked` and
#      not the wording is what the hold keys on.
#
#   C  HOLD ENGAGES / RELEASES. A login surface holds; its absence does not.
#
#   D  THE THREE CLOCKS. Aged from FIRST HELD, not from the last retry or the
#      last observation; the active-login deferral defers; the ceiling FAILS
#      OPEN. A hold that cannot lapse is `#1517` rebuilt.
#
#   E  DELIVERED ONCE AFTER THE ESCAPE. The emit must arrive, and arrive once.
#
#   F  LIVENESS FILES NO RESUBMIT AND NO RESPAWN while a hold or an expiry is
#      in play, and the verdict NAMES `auth` — `#1517` found 8 resubmits, 10
#      false `recovered` lines, and `auth` in NONE of 1,648 log lines.
#
#   G  KNOB OFF RESTORES CURRENT BEHAVIOUR EXACTLY, and the `#745` DEAD-PANE
#      GUARD PRECEDES THE ESCAPE KEYSTROKE. A write into a `remain-on-exit`
#      corpse kills the tmux SERVER — the watcher, every worker and the
#      operator's session with it.
#
# NO REAL TMUX AND NO REAL `claude`: every part drives the production functions
# directly, against committed fixtures and a temporary STATE_DIR. That is
# deliberate — the renderer claims are already pinned by the captures, and a
# suite that stands up tmux servers to re-assert them buys nothing and inherits
# the 107-byte `sun_path` hazard (`#991`).
#
# Run: bash monitor/watcher/test-auth-hold.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
MON="$REPO_ROOT/monitor"
FIX="$_test_dir/fixtures"
PS="$MON/pane-state.sh"

# ---- POPULATION DECLARATION (your-org/nexus-code#1078) --------------------
#
# Declared so `ng guards-for-diff` can SELECT this suite when a change touches
# what it reads. `test-suite-declaration-census.sh` requires it of every new
# suite, and it is right to: a suite that declares nothing is INVISIBLE to the
# index rather than excluded by it — it appears in neither `SELECTED` nor
# `CONSIDERED AND EXCLUDED`, so its absence reads as a considered exclusion and
# a `--run` exit 0 says nothing about it. The census caught exactly that about
# this file.
#
# What this suite actually READS, which is what the population must name:
#   * the subject modules — `_auth_hold.sh` (the hold), `pane-state.sh` (the
#     detector) and `_orchestrator_liveness.sh` (the liveness gate), all three
#     of which it sources or executes;
#   * `_config.sh`, because the knob DEFAULTS the clock assertions encode live
#     there, so a default changed there must re-select this suite;
#   * `_bookkeeping.sh`, which holds the `auth-login`/`auth-expired`
#     pre-registration;
#   * the four real captures. They are in the population for the reason
#     `test-pane-state.sh` states about its own fixture directory: ADDING OR
#     EDITING A CAPTURE HERE IS A CHANGE TO THIS SUITE'S ASSERTIONS, since part
#     A reads each one through the production classifier and part B derives its
#     reworded control from one of them.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s
' \
        "$_test_dir/_auth_hold.sh" \
        "$_test_dir/_orchestrator_liveness.sh" \
        "$_test_dir/_config.sh" \
        "$MON/pane-state.sh" \
        "$MON/_bookkeeping.sh" \
        "$FIX/blocked-login-method-realmodel-268.ansi" \
        "$FIX/blocked-login-signin-realmodel-268.ansi" \
        "$FIX/auth-expired-retrying-realmodel-268.ansi" \
        "$FIX/auth-expired-terminal-realmodel-268.ansi"
}
gp_handle "$@"

# THE SHARED LEDGER, adopted rather than opted out of
# (`test-summary-honesty-manifest.sh`). That guard says in as many words: *"If
# YOU are adding the suite: do NOT append a line — that opts your own new code
# out of the standard."* It is right, and the reason is this suite's own subject
# matter: `assert_*` mutates GLOBALS, so an assertion evaluated inside `( … )`,
# `$( … )` or a pipeline increments a counter that dies with the child, and a
# LOST FAILING assertion means a suite that exits 0 over a real failure. The
# ledger is a file, so it survives the subshell the counters die in — the same
# lesson this suite met twice while being written (the `PROBE_KEY` capture and
# the swallowed `env_fail`).
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
SKIP=0
# Our own `pass`/`fail` wrappers are defined AFTER the source so they win, and
# they feed the durable ledger as well as the in-memory counters — without the
# ledger write, `th_summary_and_exit` would have nothing to reconcile against
# and the protection would be nominal.
# `_th_pass` / `_th_fail` do BOTH halves — the counter AND the durable `_th_note`
# write. They are the real recorders; do not increment PASS/FAIL by hand beside
# them or every assertion counts twice.
#
# THE FIRST DRAFT OF THESE TWO LINES CALLED `_th_ledger_put`, WHICH DOES NOT
# EXIST, under `2>/dev/null || true`. So every ledger write was a silent no-op
# and the protection this suite had just been raised to was NOMINAL — the exact
# defect shape the suite's own report calls out in other people's code, produced
# here by guessing a helper name and then silencing the evidence. Caught by
# `monitor/watcher/test-helper-honesty.sh`'s undefined-helper lint, which exists
# for precisely this and is the reason `2>/dev/null` on a call you have not
# verified is never harmless.
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$label (got '$got')"
    else
        fail "$label: got '$got', want '$want'"
    fi
}
# env_fail — THE FIXTURE COULD NOT BUILD ITS SUBJECT (your-org/nexus-code#1025).
# Evidence about the MACHINE, not about the code under test. Exits 97 rather
# than counting a FAIL, so an environment fault can never be read as a #1518
# regression — the shape `#991` produced nine times in one run.
env_fail() {
    printf '  ENV-FAIL: %s\n' "$1" >&2
    printf 'test-auth-hold: refusing to report a verdict on a fixture that could not be built.\n' >&2
    exit 97
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/authhold-XXXXXX") || env_fail "mktemp -d failed"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# `auth_of <fixture>` / `state_of <fixture>` — read one token out of the
# production classifier's own output. Never re-derived here: a test that
# reimplements the parse can agree with itself while disagreeing with every
# consumer (`#1249`'s cross-check-that-agrees-with-itself shape).
# FIXTURE PRE-FLIGHT, AT TOP LEVEL, AND THE PLACEMENT IS THE ENTIRE POINT.
#
# `env_fail` exits 97 so an environment fault can never be read as a `#1518`
# regression. **An `exit` inside `$( )` exits only the SUBSHELL.** Every reader
# below is called as `"$(auth_of "$f")"`, so an `env_fail` reached from in there
# is SWALLOWED: the substitution yields the empty string, the assertion reports
# `got ''`, and the suite runs to completion — measured, **rc 0**. So a deleted
# fixture would have read as *"the detector stopped recognising the login
# screen"*, which is the exact conclusion this suite exists to make trustworthy.
#
# Found by `monitor/watcher/test-subshell-exit-guards.sh`, which flags precisely
# this shape. Two defences, because the first is the only one that can terminate
# and the second is what makes the residue legible:
#
#   (1) validate EVERY fixture HERE, at top level, where `exit` means exit;
#   (2) have the reader emit a POISON token rather than empty on any failure, so
#       if a path ever reaches it anyway the assertion fails saying so instead of
#       looking like a classification change.
_ps_fixtures_required=(
    blocked-login-method-realmodel-268 blocked-login-signin-realmodel-268
    blocked-login-codepaste-realmodel-268
    auth-expired-retrying-realmodel-268 auth-expired-terminal-realmodel-268
    idle-empty-post-turn-realmodel blocked-workspace-trust-realmodel
    blocked-unnamed-dialog-synthetic blocked-askuq-synthetic
)
for _f in "${_ps_fixtures_required[@]}"; do
    [[ -r "$FIX/$_f.ansi" ]] || env_fail "fixture missing or unreadable: $FIX/$_f.ansi"
done
[[ -x "$PS" ]] || env_fail "pane-state.sh missing or not executable: $PS"

# `_ps_tok <fixture> <token>` — one token out of the production classifier's own
# output. Never re-derived here: a test that reimplements the parse can agree
# with itself while disagreeing with every consumer (`#1249`).
#
# Emits `UNREADABLE` / `NO-OUTPUT` rather than empty, per (2) above. Note the
# absent token legitimately IS empty — that is what the `auth=` negative
# controls assert — so empty must stay a real answer and the failure modes need
# their own spellings.
_ps_tok() {
    local f="$FIX/$1.ansi" tok="$2" line
    [[ -r "$f" ]] || { printf 'UNREADABLE'; return 0; }
    line=$("$PS" --fixture "$f" 2>/dev/null) || { printf 'NO-OUTPUT'; return 0; }
    [[ -n "$line" ]] || { printf 'NO-OUTPUT'; return 0; }
    # EXACT FIELD MATCH, not a substring. `pane-state.sh` emits space-separated
    # `key=value` tokens, so splitting on whitespace and comparing the key
    # exactly is both simpler and stricter than a `sed` over the whole line.
    #
    # The regex it replaces was wrong in OPPOSITE directions for different
    # tokens, which is why it was worth recording: `[ ]auth=` needs the leading
    # space to stop `auth=` matching inside a longer key, while `state=` is the
    # FIRST field and has no leading space at all — so one pattern for both
    # silently returned EMPTY for `state`. Empty is a LEGAL answer on the `auth`
    # axis (it is what the negative controls assert), which is what made the bug
    # look like a detector regression rather than a parse error. Field equality
    # has no such asymmetry.
    awk -v t="$tok" '{
        for (i = 1; i <= NF; i++) {
            n = index($i, "=")
            if (n > 0 && substr($i, 1, n - 1) == t) { print substr($i, n + 1); exit }
        }
    }' <<<"$line"
}
_ps_line() { _ps_tok_line "$1"; }
_ps_tok_line() {
    local f="$FIX/$1.ansi"
    [[ -r "$f" ]] || { printf 'UNREADABLE'; return 0; }
    "$PS" --fixture "$f" 2>/dev/null
}
auth_of()  { _ps_tok "$1" auth; }
state_of() { _ps_tok "$1" state; }
ovl_of()   { _ps_tok "$1" overlay; }

echo "== A. detector, against the REAL 2.1.268 captures =="

# The two `/login` frames. BOTH halves asserted on each: `state=blocked` is
# what the hold keys on, `auth=login` is what names it.
for f in blocked-login-method-realmodel-268 blocked-login-signin-realmodel-268; do
    assert_eq "A/$f state"   "$(state_of "$f")" blocked
    assert_eq "A/$f auth"    "$(auth_of  "$f")" login
    assert_eq "A/$f overlay" "$(ovl_of   "$f")" login
done

# The two logged-out renders. `state=idle` is ASSERTED, not merely tolerated:
# it is the measured fact that makes this surface dangerous (idle is on the
# kill allowlist AND is the canonical paste-me state), and if a future release
# makes it read `busy` the premise of the liveness gate has changed and this
# suite should say so rather than silently pass.
for f in auth-expired-retrying-realmodel-268 auth-expired-terminal-realmodel-268; do
    assert_eq "A/$f auth"  "$(auth_of  "$f")" expired
    assert_eq "A/$f state" "$(state_of "$f")" idle
done

# NEGATIVE CONTROLS. Without these the detector could match everything and
# every assertion above would still pass.
for f in idle-empty-post-turn-realmodel blocked-workspace-trust-realmodel \
         blocked-unnamed-dialog-synthetic blocked-askuq-synthetic; do
    assert_eq "A/neg $f carries NO auth= field" "$(auth_of "$f")" ""
done
assert_eq "A/neg workspace-trust overlay unchanged" \
    "$(ovl_of blocked-workspace-trust-realmodel)" workspace-trust
assert_eq "A/neg unnamed dialog overlay unchanged" \
    "$(ovl_of blocked-unnamed-dialog-synthetic)" dialog

echo "== B. POSITIVE CONTROL: an UNRECOGNISED login surface must not read 'no login' =="

# Take the REAL login capture and rewrite every one of the three recognised
# strings, simulating a vendor reword. `auth=login` is EXPECTED to be lost —
# that is honest — but `state=blocked` must survive, because that is what the
# watcher's hold and `paste-followup.sh:889` actually refuse on. If this part
# ever goes red, the safe-failure claim in `pane-state.sh`'s `_dialog_is_login`
# header is FALSE and the reword has become a silent regression.
reworded="$WORK/login-reworded.ansi"
sed -e 's/Login/Authentication/g' \
    -e 's/Select login method:/Pick an authentication route:/' \
    -e 's/How do you want to sign in?/Which route?/' \
    "$FIX/blocked-login-method-realmodel-268.ansi" > "$reworded" \
    || env_fail "could not build the reworded fixture"
grep -qiE '^[[:space:]]*Login[[:space:]]*$|Select login method:|How do you want to sign in' "$reworded" \
    && env_fail "the reworded fixture still contains a recognised string — the sed did not take, so part B would assert nothing"
rw_line=$("$PS" --fixture "$reworded" 2>/dev/null)
rw_state=$(sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$rw_line")
rw_auth=$(sed -n 's/.*[ ]auth=\([a-z-]*\).*/\1/p' <<<"$rw_line")
assert_eq "B reworded login STILL classifies blocked (the hold's real key)" "$rw_state" blocked
if [[ -z "$rw_auth" ]]; then
    pass "B reworded login loses auth=login — stated honestly; the STRUCTURAL gate above is what protects the operator"
else
    pass "B reworded login still carries auth=$rw_auth (a disjunct survived the reword — better than required)"
fi

echo "== C/D/E/F/G. the hold, driven through the production module =="

# One STATE_DIR per arm. `_auth_hold.sh` is sourced with a stub logger that
# CAPTURES, so the log assertions are about what the module actually emitted.
export STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR" || env_fail "could not create STATE_DIR"
LOGCAP="$WORK/log"
ALERTCAP="$WORK/alerts"
: > "$LOGCAP"; : > "$ALERTCAP"
_cap_log()   { printf '%s\n' "$1" >> "$LOGCAP"; }
_cap_alert() { printf '%s\n' "$1" >> "$ALERTCAP"; }
_AUTH_HOLD_LOG_FN=_cap_log
_AUTH_HOLD_ALERT_FN=_cap_alert

# A MISSING SUBJECT IS A **FAILURE**, NOT AN ENVIRONMENT SKIP — and the
# distinction is the whole reason `env_fail` exits 97 rather than 1. `env_fail`
# means *the machine could not build my fixture*; an absent `_auth_hold.sh`
# means *the feature is not here*, which is precisely the regression this suite
# exists to catch. Routing it to `env_fail` would make a DELETION of the module
# read as "skipped" — a green-shaped answer for the loudest possible defect, and
# the same shape as every silent zero in this repo. Verified by running this
# suite against `4f73e0e7`, where it must exit 1.
if [[ ! -r "$_test_dir/_auth_hold.sh" ]]; then
    fail "_auth_hold.sh does not exist — the login hold is ABSENT, so the watcher pastes straight into the operator's /login dialog and its trailing Enter selects a login method (your-org/nexus-code#1518). Parts C-G cannot run."
    th_summary_and_exit
fi
# shellcheck source=_auth_hold.sh
source "$_test_dir/_auth_hold.sh" || {
    fail "_auth_hold.sh exists but could not be sourced"
    th_summary_and_exit
}
if ! declare -F _auth_hold_active >/dev/null 2>&1; then
    fail "_auth_hold_active is undefined after sourcing _auth_hold.sh — the hold gate the emit ladder calls does not exist"
    th_summary_and_exit
fi

# The probe is the ONE seam: the real one needs a live tmux pane. Override it
# with a scripted reading so the CLOCKS and the LADDER are exercised against
# the production code. The seam supplies the pane-state LINE's parsed fields,
# which part A has just proved the real classifier produces for the real
# captures — so this stub cannot invent a reading the binary does not give.
PROBE_REPLY=""
# The captured arguments go to a FILE, not to variables. The production code
# calls this inside `probe=$(_auth_hold_probe …)` — a SUBSHELL — so a variable
# assignment here is discarded at the closing paren and every assertion on it
# reads the empty string. Measured while writing this suite: four C0 assertions
# failed with `got ''`, which reads as "the production code passed nothing"
# rather than "my fixture cannot see what it passed". A file crosses the
# subshell boundary; a variable does not.
PROBE_ARGS="$WORK/probe-args"
: > "$PROBE_ARGS"
_auth_hold_probe() {
    printf '%s\t%s\n' "${1:-}" "${2:-}" > "$PROBE_ARGS"
    [[ -n "$PROBE_REPLY" ]] || return 1
    printf '%s' "$PROBE_REPLY"
}
probe_key()    { cut -f1 "$PROBE_ARGS" 2>/dev/null; }
probe_expect() { cut -f2 "$PROBE_ARGS" 2>/dev/null; }

row_path=$(_auth_hold_state_path)
reset_arm() { rm -f "$row_path" "$(_auth_hold_alert_stamp_path)" "$(_auth_hold_held_log_path)"; : > "$LOGCAP"; : > "$ALERTCAP"; }

# ---- C0. the probe is keyed on the window INDEX, for the shared cache ---
#
# NOT a style point, and it is untestable from the outside: the `#562` pane
# cache is keyed on the probe TARGET STRING, and the authoritative recorder
# writes it keyed on `$window_index`
# (`_idle_probe.sh:864: _pane_cache_write "$window_index"`). A name-keyed read
# misses EVERY time, so at the `auth_hold` task's 5 s cadence the module would
# fork `pane-state.sh` twelve times a minute on the watcher's hot path while
# appearing to use the cache. Nothing fails; the cost is invisible. So it is
# asserted here, because a revert to the name would otherwise be silent.
#
# The second argument must stay the NAME: it is `_pane_cache_read`'s
# window-index-reuse guard, which only works if it is the name the caller
# believes the index belongs to.
#
# Stubs `resolve_window_index` — the PUBLIC resolver in `monitor/_tmux-window.sh`
# — because that is the only thing `_auth_hold_window_index` depends on. An
# earlier cut stubbed `_over_limit_resolve_window_index` instead, matching a
# dependency on another module's PRIVATE helper that has since been removed; see
# that function's header for the lint-coverage side effect the private coupling
# had.
reset_arm; : > "$PROBE_ARGS"
resolve_window_index() { printf '7'; }
PROBE_REPLY="blocked login 111"
_auth_hold_observe orchestrator
assert_eq "C0 observe probes with the resolved INDEX (cache hit, not a fork every 5 s)" "$(probe_key)" 7
assert_eq "C0 …and passes the NAME as the cache's index-reuse guard" "$(probe_expect)" orchestrator
reset_arm; : > "$PROBE_ARGS"
_auth_hold_auth_expired orchestrator >/dev/null 2>&1
assert_eq "C0 the liveness predicate is index-keyed too" "$(probe_key)" 7
# A resolver that cannot answer must DEGRADE TO THE NAME, not refuse: the probe
# then forks, which is a cost, where refusing would silently turn the hold OFF
# on a tmux hiccup.
reset_arm; : > "$PROBE_ARGS"
resolve_window_index() { return 1; }
PROBE_REPLY="blocked login 111"
_auth_hold_observe orchestrator
assert_eq "C0 an unresolvable index degrades to the NAME (forks) rather than refusing to observe" "$(probe_key)" orchestrator
if _auth_hold_active; then pass "C0 …and the hold still engages on the degraded path"; else fail "C0 an unresolvable index silently turned the hold OFF"; fi
unset -f resolve_window_index

# ---- C. engage / release ------------------------------------------------
reset_arm
PROBE_REPLY="blocked login 111"
_auth_hold_observe orchestrator
if _auth_hold_active; then pass "C login dialog → hold ACTIVE"; else fail "C login dialog did NOT engage the hold"; fi
grep -q 'ENGAGED' "$LOGCAP" && pass "C the hold is VISIBLE in the log (#592: a muted channel must announce itself)" \
    || fail "C no ENGAGED line in the log"
grep -qE 'a /login dialog is open|emits are HELD' "$ALERTCAP" \
    && pass "C the operator is notified out-of-band, once" \
    || fail "C no sandbox-notify-class alert on entering the hold"
alert_n=$(grep -c . "$ALERTCAP")
_auth_hold_observe orchestrator; _auth_hold_observe orchestrator
assert_eq "C notified ONCE, not once per cycle (#976)" "$(grep -c . "$ALERTCAP")" "$alert_n"

# THE LIVE-vs-QUOTED PROTECTION HAS MOVED, AND THIS RECORDS THE MIGRATION
# RATHER THAN DELETING THE ASSERTION.
#
# Before F1/F2 this read: *"`auth=login` without `state=blocked` must NOT hold —
# a pane merely QUOTING a login frame would otherwise silence the board."* That
# was enforced by the gate's `&&`, and the `&&` is exactly what F1 removed.
#
# The protection did not go away; it moved to where it belongs. It is now a
# property of the DETECTOR: `pane-state.sh` sets `auth=login` only when the pane
# has NO `❯<NBSP>` REPL input row, i.e. only when a dialog has genuinely replaced
# the REPL. A pane discussing a login screen is a running REPL and keeps its row,
# so it is never labelled in the first place — and part F2's NEG assertion checks
# that on a REAL capture with a REPL row appended, which is stronger evidence
# than this arm ever had (it asserted on a hand-written probe string).
#
# So what is asserted here is the consequence: given a label the detector WOULD
# NOT have emitted, the hold does engage — and that is correct, because reaching
# this arm means something upstream already established a live dialog. Stating it
# as an explicit contract change rather than a quiet deletion, because deleting
# an assertion that was protecting something is how a regression gets a green.
reset_arm
PROBE_REPLY="idle login 111"
_auth_hold_observe orchestrator
if _auth_hold_active; then
    pass "C auth=login alone HOLDS (post-F1 disjunction); live-vs-quoted is now enforced in the DETECTOR — see F2 NEG"
else
    fail "C auth=login alone did not hold, so the disjunction's labelled arm is not wired — the code-paste step is uncovered"
fi

reset_arm
PROBE_REPLY="blocked login 111"; _auth_hold_observe orchestrator
PROBE_REPLY="idle none 222";     _auth_hold_observe orchestrator
if _auth_hold_active; then fail "C hold did not RELEASE when the dialog went away"; else pass "C hold RELEASES when the login dialog is gone"; fi
grep -q 'RELEASED' "$LOGCAP" && pass "C the release is in the log" || fail "C no RELEASED line"

# An unreadable pane must neither create nor destroy a hold.
reset_arm
PROBE_REPLY=""
_auth_hold_observe orchestrator
if _auth_hold_active; then fail "C an UNREADABLE pane created a hold (not knowing is not evidence of a login)"; else pass "C an unreadable pane creates NO hold"; fi
PROBE_REPLY="blocked login 111"; _auth_hold_observe orchestrator
PROBE_REPLY=""; _auth_hold_observe orchestrator
if _auth_hold_active; then pass "C an unreadable pane does not CLEAR a live hold (it ages out instead)"; else fail "C one unreadable probe destroyed a live hold — the paste re-opens on a tmux hiccup"; fi

# The clock and the row writer, hoisted above F1/F3 because both need them.
# Every arm back-dates the row rather than sleeping: the clocks are arithmetic on
# epochs, and a suite that slept an hour to prove a 3600 s threshold would never
# be run.
now=$(date +%s)
write_row() {  # <first_seen_ago> <last_observed_ago> <hash_change_ago> [auth-label]
    # kind is `dialog` since F1 — the gate is STRUCTURAL (`state=blocked`), and
    # `login` is no longer a legal kind. The 6th field is the `auth=` label,
    # which is DIAGNOSIS only: a row whose label is `none` must hold exactly as
    # hard as one labelled `login`, and part F1b below asserts that.
    printf 'dialog\t%s\t%s\t111\t%s\t%s\n' \
        "$(( now - $1 ))" "$(( now - $2 ))" "$(( now - $3 ))" "${4:-login}" > "$row_path"
}

# ---- F2. THE CODE-PASTE STEP — the login screen neither axis used to cover
#
# Skeptic w237sk F2: `auth=login` had ONE call site, inside
# `_name_menu_dialog_kind`, gated on `_has_menu_dialog_frame` — so it required a
# MULTI-OPTION SELECT MENU and was unreachable for any other login screen.
# w237sk could not capture those screens (no `CLAUDE_BIN` in a worktree) and said
# so rather than guessing. I captured them; the measurement was worse than the
# prediction:
#
#     method menu     LIVE: state=blocked overlay=login auth=login   <- held
#     code-paste step LIVE: state=empty                              <- NOT held
#
# And the code-paste step is the screen where a stray paste is WORST: the emit
# body lands in the auth-code field and the trailing Enter SUBMITS it, failing
# the login outright. `state=empty` can never join the hold's structural arm —
# it means "don't know yet" and is the commonest mid-render reading — so
# `auth=login` has to reach it, which is why the gate is a disjunction.
assert_eq "F2 the code-paste step carries auth=login (reachable WITHOUT a menu frame)" \
    "$(auth_of blocked-login-codepaste-realmodel-268)" login
# THE LIVE-vs-QUOTED DISCRIMINATOR, asserted rather than trusted: the capture
# must have no REPL input row, which is what makes "the dialog replaced the REPL"
# a structural fact instead of a margin.
if grep -qF "❯$(printf '\u00a0')" "$FIX/blocked-login-codepaste-realmodel-268.ansi"; then
    fail "F2 the code-paste capture HAS a REPL input row — then it is a pane DISCUSSING the screen, not sitting on it, and the live-vs-quoted test this disjunct rests on is not what it claims"
else
    pass "F2 the code-paste capture has NO REPL input row — the dialog has replaced the REPL (live, not quoted)"
fi
# The NEGATIVE control for that discriminator, and it is the one that stops this
# disjunct labelling every agent that reads #1518: the same login text with a
# REPL row present must NOT be labelled.
_cp_quoted="$WORK/login-quoted.ansi"
{ sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$FIX/blocked-login-codepaste-realmodel-268.ansi" | grep -vE '^[[:space:]]*$'
  printf '\xe2\x9d\xaf\xc2\xa0\n'; } > "$_cp_quoted"
grep -qF "Paste code here if prompted" "$_cp_quoted" || env_fail "could not build the quoted control (login text missing)"
_cp_q_auth=$("$PS" --fixture "$_cp_quoted" 2>/dev/null | awk '{for(i=1;i<=NF;i++){n=index($i,"="); if(n>0&&substr($i,1,n-1)=="auth"){print substr($i,n+1);exit}}}')
assert_eq "F2 NEG the same login text WITH a REPL input row is NOT labelled (a pane discussing #1518 must not hold the board)" "$_cp_q_auth" ""

# ISOLATING DISJUNCT (d). The assertion above does NOT isolate it — the
# code-paste frame also carries a bare `Login` header, so disjunct (a) covers it
# and deleting (d) leaves the suite green. Measured: that mutant survived. It is
# the same "an assertion defended by a different guard than the one it names"
# class this bundle already hit three times in its own clocks, and w237sk
# independently noted the disjuncts are redundant per fixture.
#
# Redundancy is a virtue here and the test should still be able to see each arm.
# Strip the `Login` header and (d) is the only disjunct left standing — which is
# also the realistic rot case: a vendor that renames the frame's title.
# BUILT FROM THE STRIPPED TEXT, and that is not incidental. The first cut ran the
# header-rewrite over the RAW ANSI capture, where the row is not `   Login` but
# `   \x1b[1mLogin\x1b[0m` — so the `sed` matched nothing, and the
# precondition guard below (which also read the raw file) found no bare `Login`
# row and duly concluded the strip had WORKED. A false confirmation, of exactly
# the shape this bundle keeps meeting: the guard and the subject were looking at
# different representations. `_dialog_is_login` reads the STRIPPED text, so the
# control must be built and checked there.
_cp_nohdr="$WORK/codepaste-no-header.ansi"
sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$FIX/blocked-login-codepaste-realmodel-268.ansi" \
    | sed -e 's/^\([[:space:]]*\)Login[[:space:]]*$/\1Sign in/' > "$_cp_nohdr"
grep -qiE '^[[:space:]]*Login[[:space:]]*$' "$_cp_nohdr" \
    && env_fail "the header-rewrite did not take — this control would assert nothing"
grep -qF 'Paste code here if prompted' "$_cp_nohdr" \
    || env_fail "the header-rewrite removed disjunct (d)'s literal too"
_cp_nh_auth=$("$PS" --fixture "$_cp_nohdr" 2>/dev/null | awk '{for(i=1;i<=NF;i++){n=index($i,"="); if(n>0&&substr($i,1,n-1)=="auth"){print substr($i,n+1);exit}}}')
assert_eq "F2 disjunct (d) ALONE labels the code-paste step when the Login header is reworded away" "$_cp_nh_auth" login

# ---- F7. DISJUNCT (a) IS ANCHORED TO THE DIALOG REGION
#
# Skeptic w237sk F7: `_dialog_is_login` received the WHOLE pane, so a bare
# `Login` row anywhere in the transcript named an unrelated dialog a login one.
# Measured by w237sk: the unnamed-dialog fixture plus one transcript row `Login`
# produced `overlay=login auth=login`.
#
# Post-F1 the COST is the label only — the hold keys on `state=blocked` too, so a
# mis-named dialog is still held and the notify says the kind is unknown. So this
# is an anchoring improvement, and the assertion is about the NAMING.
_f7="$WORK/f7-unnamed-plus-login.ansi"
{ printf 'Login\n'
  for _i in $(seq 1 30); do printf 'filler transcript row %s\n' "$_i"; done
  cat "$FIX/blocked-unnamed-dialog-synthetic.ansi"; } > "$_f7"
_f7_state=$("$PS" --fixture "$_f7" 2>/dev/null | awk '{for(i=1;i<=NF;i++){n=index($i,"="); if(n>0&&substr($i,1,n-1)=="state"){print substr($i,n+1);exit}}}')
_f7_auth=$("$PS" --fixture "$_f7" 2>/dev/null | awk '{for(i=1;i<=NF;i++){n=index($i,"="); if(n>0&&substr($i,1,n-1)=="auth"){print substr($i,n+1);exit}}}')
assert_eq "F7 an unnamed dialog with a distant transcript 'Login' row is still BLOCKED (so it is still held)" "$_f7_state" blocked
assert_eq "F7 …and is NOT mis-named a login (disjunct (a) is anchored to the dialog region)" "$_f7_auth" ""

# AND THE HOLD ITSELF, on the production reading of that screen. `state=empty`
# is deliberately used here: that is what the live pane reports, and it is the
# whole reason the structural arm alone is insufficient.
reset_arm
PROBE_REPLY="empty login 111"
_auth_hold_observe orchestrator
if _auth_hold_active; then
    pass "F2 state=empty + auth=login HOLDS — the code-paste step is covered by the labelled arm"
else
    fail "F2 the code-paste step (state=empty auth=login) did NOT hold: the emit would paste into the auth-code field and its trailing Enter would submit it, failing the operator's login (w237sk F2)"
fi
# …and `empty` WITHOUT the label must still not hold, or "don't know yet" mutes
# the board on every mid-render cycle.
reset_arm
PROBE_REPLY="empty none 111"
_auth_hold_observe orchestrator
if _auth_hold_active; then
    fail "F2 state=empty with NO auth label engaged the hold — 'empty' is the commonest mid-render reading, so this would mute the board continuously"
else
    pass "F2 state=empty alone does NOT hold (the labelled arm is required)"
fi

# ---- F4. BOTH CLASSIFICATION ROUTES, and the disjunction earns its keep again
#
# Skeptic w237sk F4: the stated premise that the orchestrator "normally takes"
# the heartbeat route is false — `orchestrator-settings.json` runs no
# `worker-heartbeat.sh` and there is no `heartbeat/orchestrator.json`. Worse, the
# comment justifying the `emit()` placement described a hazard that `auth=login`
# then INSTANTIATED: it was set at the `_has_blocked_overlay` arm, which the
# heartbeat route never calls, so the field gating the hold was renderer-only.
#
# Measured here on BOTH routes, and the result is why the F1/F2 disjunction is
# the right shape rather than merely a safer one — on the heartbeat route the two
# arms cover DIFFERENT states and neither alone suffices:
#
#   renderer path                  state=blocked  auth=login   both arms
#   heartbeat idle_prompt          state=idle     auth=login   LABELLED arm only
#   heartbeat permission_prompt    state=blocked  (no auth)    STRUCTURAL arm only
#
# So whichever route runs and whichever heartbeat state it reports, at least one
# arm fires. #1520 proposes giving the orchestrator worker-style hook coverage;
# that is the day the heartbeat route starts running for this window, and these
# assertions are what will say whether the hold survived it.
_hbdir="$WORK/hb"; mkdir -p "$_hbdir"
_hb_probe() {   # <heartbeat-state> <fixture> <token>
    printf '{"state":"%s","last_activity":%s,"last_turn_end":%s}\n' "$1" "$now" "$now" \
        > "$_hbdir/h.json"
    "$PS" --fixture "$FIX/$2.ansi" --heartbeat-file "$_hbdir/h.json" --now "$now" 2>/dev/null \
        | awk -v t="$3" '{for(i=1;i<=NF;i++){n=index($i,"="); if(n>0&&substr($i,1,n-1)==t){print substr($i,n+1);exit}}}'
}
# PRECONDITION: the heartbeat route must actually be TAKEN, or every assertion
# below is a renderer-path assertion wearing a heartbeat label. `idle` on a
# capture the renderer calls `blocked` is the proof that it was.
_hb_state=$(_hb_probe idle_prompt blocked-login-method-realmodel-268 state)
if [[ "$_hb_state" == "idle" ]]; then
    pass "F4 the heartbeat route is genuinely taken (it reports idle where the renderer reports blocked)"
else
    env_fail "the heartbeat route was not taken (state=$_hb_state); every F4 assertion would be a renderer-path assertion mislabelled"
fi
assert_eq "F4 heartbeat idle_prompt on a login frame still carries auth=login (the LABELLED arm covers the route the structural one loses)" \
    "$(_hb_probe idle_prompt blocked-login-method-realmodel-268 auth)" login
assert_eq "F4 …and on the non-menu code-paste frame too" \
    "$(_hb_probe idle_prompt blocked-login-codepaste-realmodel-268 auth)" login
assert_eq "F4 heartbeat permission_prompt classifies blocked (the STRUCTURAL arm covers what the label loses)" \
    "$(_hb_probe permission_prompt blocked-login-method-realmodel-268 state)" blocked
# And the hold must engage for each of the three (route, state) pairs measured.
for _pair in "blocked login" "idle login" "blocked none"; do
    reset_arm
    PROBE_REPLY="$_pair 111"
    _auth_hold_observe orchestrator
    if _auth_hold_active; then
        pass "F4 the hold engages for (state auth)=($_pair)"
    else
        fail "F4 the hold did NOT engage for (state auth)=($_pair) — one of the three measured route/state combinations is uncovered"
    fi
done

# ---- D1. THE ENGAGED LINE NAMES WHICH ARM FIRED
#
# Skeptic w237sk D1: the line asserted *"the hold keys on state=blocked, NOT on
# auth"* byte-identically in both arms, and on the code-paste screen — where the
# label arm is the ONLY cover — both clauses are false. Round-1 F1's shape one
# level down: a claim about the gate that the gate contradicts, and F1 is how a
# false safety claim reached three documents.
#
# Three arms, three statements, asserted separately because a single
# "mentions the arm" check would pass on any wording.
reset_arm
PROBE_REPLY="blocked login 111"; _auth_hold_observe orchestrator
if grep -q 'BOTH arms hold this frame' "$LOGCAP"; then
    pass "D1 blocked+login says BOTH arms hold it"
else
    fail "D1 blocked+login does not name both arms (got: $(grep ENGAGED "$LOGCAP" | tail -c 170))"
fi
reset_arm
PROBE_REPLY="blocked none 111"; _auth_hold_observe orchestrator
if grep -q 'the STRUCTURAL arm holds it' "$LOGCAP"; then
    pass "D1 blocked+none says the STRUCTURAL arm holds it"
else
    fail "D1 blocked+none does not name the structural arm (got: $(grep ENGAGED "$LOGCAP" | tail -c 170))"
fi
# THE ONE THAT MATTERS: the code-paste case, where the old line was false.
reset_arm
PROBE_REPLY="empty login 111"; _auth_hold_observe orchestrator
if grep -q 'ONLY the LABELLED arm' "$LOGCAP"; then
    pass "D1 empty+login says ONLY the labelled arm holds it"
else
    fail "D1 empty+login does not say the labelled arm is the only cover (got: $(grep ENGAGED "$LOGCAP" | tail -c 170))"
fi
if grep -q 'no structural backstop' "$LOGCAP" && grep -q 'WOULD drop this hold' "$LOGCAP"; then
    pass "D1 …and states that arm's OWN exposure: no structural backstop, a reword would drop it"
else
    fail "D1 the labelled-only case does not state its own exposure — a diagnostic that reassures where it should warn is how F1 reached three documents"
fi
# NEGATIVE CONTROL: the false claim must be GONE, not merely joined by a true one.
if grep -q 'NOT on auth' "$LOGCAP"; then
    fail "D1 the superseded unconditional claim ('NOT on auth') is still emitted — adding a true sentence beside a false one leaves the false one to be quoted"
else
    pass "D1 NEG the superseded unconditional claim is gone, not merely supplemented"
fi

# ---- D2. AN ACTIVELY-WORKING PANE IS NOT SITTING ON A LOGIN SCREEN
#
# Skeptic w237sk D2, reproduced exactly before fixing: the label arm's
# live-vs-quoted precondition (no `❯<NBSP>` row) coincides with a reading `#603`
# measured on a pane 4m38s into a verification pass, and 11 real `busy` captures
# in this corpus lack that row — including the dialog family's own live-vs-quoted
# control. Splicing in the literal as an orchestrator reading `GUIDE.md` or
# `#1518` would render it gave `state=busy … auth=login`, i.e. the watcher held
# on a working pane.
#
# w237's earlier NEG built its quoted case by APPENDING a REPL row, so it covered
# panes WITH the row and structurally could not see this population — the suite's
# claim that live-vs-quoted was "enforced in the DETECTOR" was broader than its
# evidence. This is that population.
_d2_spliced="$WORK/d2-busy-quoting.ansi"
{ sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$FIX/busy-dialog-quoted-midrender-synthetic.ansi"
  printf "the GUIDE entry says the literal is 'Paste code here if prompted'\n"; } > "$_d2_spliced"
# PRECONDITIONS, both directions, so this control cannot pass vacuously.
grep -qF 'Paste code here if prompted' "$_d2_spliced" \
    || env_fail "the D2 splice did not take — the quoted literal is absent, so this control asserts nothing"
grep -qF "❯$(printf '\u00a0')" "$_d2_spliced" \
    && env_fail "the D2 capture HAS a REPL row — then it is the already-covered with-row population, not D2's"
_d2_state=$("$PS" --fixture "$_d2_spliced" 2>/dev/null | awk '{for(i=1;i<=NF;i++){n=index($i,"="); if(n>0&&substr($i,1,n-1)=="state"){print substr($i,n+1);exit}}}')
_d2_auth=$("$PS" --fixture "$_d2_spliced" 2>/dev/null | awk '{for(i=1;i<=NF;i++){n=index($i,"="); if(n>0&&substr($i,1,n-1)=="auth"){print substr($i,n+1);exit}}}')
assert_eq "D2 the spliced capture really is busy and row-less (the population the old NEG could not see)" "$_d2_state" busy
assert_eq "D2 …and a BUSY pane quoting a login literal is NOT labelled" "$_d2_auth" ""
# WHERE THE EXCLUSION LIVES, DECIDED EXPLICITLY AND ASSERTED AS DECIDED.
#
# It is in the DETECTOR only — `pane-state.sh` never emits the pairing — and NOT
# duplicated in `_auth_hold`. The hold therefore DOES act on a `(busy, login)`
# pairing if one is handed to it, and the assertion below records that rather
# than pretending otherwise, because an assertion that describes a second
# enforcement point I did not build is exactly the F1 error again.
#
# WHY ONE PLACE. Two copies of a four-state list is a drift risk of the kind this
# report already names as Infrastructure Issue 6 about the mirrored hold
# implementations; and "is this pane working?" is a fact about the PANE, so it
# belongs where the pane is read. A predicate cannot be shared cheaply —
# `pane-state.sh` is a script, not a sourceable library.
#
# THE RESIDUAL, STATED: a watcher running against a DIFFERENT `pane-state.sh`
# than this tree's (a mixed checkout, an older primary) could hand the hold that
# pairing and be held. Bounded and self-releasing — w237sk measured the cost of
# a false hold as a DELAYED emit, not a silenced board: the emit is archived,
# re-composed, and the hold clears the next cycle the gate reads false, with the
# ceiling behind that. Accepted over a duplicated list.
reset_arm
PROBE_REPLY="busy login 111"
_auth_hold_observe orchestrator
if _auth_hold_active; then
    pass "D2 the hold acts on a (busy, login) pairing — by design: the exclusion is enforced in the DETECTOR only, which never emits it (residual stated in the header above)"
else
    fail "D2 the hold refused (busy, login) — that means a second copy of the exclusion list has appeared in _auth_hold, which is the drift this bundle's own Infrastructure Issue 6 is about; remove it or make it the single source"
fi
# THE CONTRACT THAT MAKES THAT SAFE, asserted directly against the real detector
# rather than inferred: for every excluded state, no login capture is labelled.
# This is the property the hold relies on, so it is the one that must be tested.
# DIRECTION, asserted rather than argued, because a MISSED login is unbounded
# where a delayed emit is not: every state a REAL login frame reaches must still
# be labelled.
for _f in blocked-login-method-realmodel-268 blocked-login-signin-realmodel-268 blocked-login-codepaste-realmodel-268; do
    assert_eq "D2 DIRECTION $_f is still labelled (the exclusion removed nothing protective)" "$(auth_of "$_f")" login
done
# THE EXCLUSION LIST IS COMPLETE, checked against `pane-state.sh`'s OWN source
# rather than by driving four states a fixture cannot reach. `working-background`
# and `working-self-paced` come from `_finalize_idle_verdict`'s process-tree walk
# and `over-limit` from a hook stamp — none is reachable from a bare `--fixture`
# capture, so a behavioural assertion for them would be untestable here and a
# pass would mean nothing. What IS checkable is that the list the code applies is
# the list `_BK_ACTIVE_STATES` already calls active, minus the two that are
# never-paste for other reasons (`blocked` is the structural arm itself;
# `user-typing` is the operator, which the orchestrator's own never-trample rule
# covers upstream).
_d2_list=$(sed -n 's/^ *for _ps_s in \(.*\); do$/\1/p' "$MON/pane-state.sh" | head -1)
# …NARROWED by w239sk F1 to the two GENERATING states: `working-background` and
# `working-self-paced` are refinements of an IDLE base verdict, so the no-row
# discriminator is sound for them, and excluding them made the cc-update
# restart veto inert on the heartbeat route. Driven end-to-end (real emitter →
# gate) in test-pane-state-restart-quiescence.sh E2a–E2d.
assert_eq "D2 the excluded-state list in pane-state.sh is exactly the two GENERATING states" \
    "$_d2_list" "busy over-limit"
# …and it is REACHED, not dead code: the busy capture above proves the arm fires.
if grep -q '_ps_active == 0' "$MON/pane-state.sh"; then
    pass "D2 the exclusion gates the label arm (the busy splice above proves it is reached)"
else
    fail "D2 the exclusion is not wired into the label arm's condition"
fi

# ---- F1. THE GATE IS STRUCTURAL — the assertion the first cut could not make
#
# Skeptic w237sk F1. The original part B asserted a `pane-state.sh` property —
# *"a reworded login capture still classifies `state=blocked`"* — and then the
# report, `_auth_hold.sh`'s header and `skills/nexus.cc-update/GUIDE.md` all
# concluded that the HOLD therefore survives a vendor reword. **It did not.** The
# gate required `auth == login && state == blocked`, so the reword dropped it and
# the ladder reached `paste_with_retry`. A green test that is structurally unable
# to detect its own subject is worse than no test, because it is cited.
#
# These assertions call `_auth_hold_active`. That is the whole difference.
reset_arm
PROBE_REPLY="blocked none 111"
_auth_hold_observe orchestrator
if _auth_hold_active; then
    pass "F1 a REWORDED login dialog (state=blocked, auth=none) STILL HOLDS — the gate is state=blocked, not auth=login"
else
    fail "F1 a reworded login dialog did NOT hold: the gate keyed on auth=login, so a vendor reword of the three login strings drops the hold and the watcher pastes into the operator's /login screen — the exact failure the report, _auth_hold.sh's header and skills/nexus.cc-update/GUIDE.md all promise cannot happen (w237sk F1)"
fi
assert_eq "F1 …and the row records the label as 'none', so the DIAGNOSIS degrades and the protection does not" \
    "$(cut -f6 "$row_path" 2>/dev/null)" none
# The notification must NOT claim a login flow it cannot see. Orchestrator's
# instruction: a confident wrong noun at 3am is worse than a vague right one.
if grep -qE 'not one this watcher names|unknown kind' "$ALERTCAP"; then
    pass "F1 …and the notify says the dialog kind is UNKNOWN rather than guessing 'login'"
else
    fail "F1 the notify claims a specific dialog kind for auth=none — a confident wrong noun (got: $(tr '\n' ' ' < "$ALERTCAP" | cut -c1-120))"
fi

# THE WIDENING IS REAL AND INTENDED: any blocked dialog holds, because pasting
# into any dialog is the hazard (#1200) and the trailing Enter is its confirm.
for _ovl in workspace-trust askuq permission bypass-permissions; do
    reset_arm
    PROBE_REPLY="blocked none 111"
    _auth_hold_observe orchestrator
    if _auth_hold_active; then
        pass "F1 a blocked '$_ovl'-class dialog holds too — the hazard is the CONFIRM, not the login"
    else
        fail "F1 a blocked dialog did not hold (overlay class '$_ovl')"
    fi
done

# …and the widening must not reach a pane that is merely BUSY or IDLE.
for _st in idle busy user-typing empty over-limit; do
    reset_arm
    PROBE_REPLY="$_st none 111"
    _auth_hold_observe orchestrator
    if _auth_hold_active; then
        fail "F1 state=$_st engaged the emit hold — the gate has widened past 'blocked' and the board can now be muted by an ordinary pane"
    else
        pass "F1 state=$_st does NOT hold (the widening stops at blocked)"
    fi
done

# ---- F3. THE EXPIRY ARM HAS A CEILING, and it bounds the WIDENED population
#
# Skeptic w237sk F3: the emit hold was bounded twice and the LIVENESS gate — the
# one suppressing the RESPAWN — was bounded not at all. Unbounded, a
# wedged-but-present orchestrator is reported `healthy reason=auth-expired`
# forever: the pane is frozen, so the text that suppresses the remedy can never
# scroll out, and `_bottom_rows 15` bounds ROWS, not TIME.
#
# The orchestrator asked for the F1 widening and this ceiling to land together,
# with the bound demonstrably exercised on the widened case. Both arms below.
reset_arm
rm -f "$(_auth_hold_expiry_path)"
PROBE_REPLY="idle expired 111"
_auth_hold_observe orchestrator
if _auth_hold_auth_expired orchestrator; then pass "F3 a fresh expiry suppresses the liveness remedies"; else fail "F3 a fresh expiry did not suppress"; fi
# Back-date the expiry past the ceiling: it must FAIL OPEN.
printf '%s\t%s\n' "$(( now - 9000 ))" "$now" > "$(_auth_hold_expiry_path)"
if _auth_hold_auth_expired orchestrator; then
    fail "F3 an expiry 9000 s old still suppressed resubmit AND respawn — past the 7200 s ceiling this must FAIL OPEN, or a WEDGED orchestrator is reported healthy indefinitely, which is #1517's shape one layer over"
else
    pass "F3 the expiry arm FAILS OPEN past max_hold_seconds (9000 s > 7200 s)"
fi
grep -q 'ceiling REACHED' "$LOGCAP" && pass "F3 …and says so in the log, naming the ceiling" || fail "F3 the fail-open is silent"
# The WIDENED case: the hold arm now fires on any dialog, so its ceiling must
# bound that population too — asserted here rather than assumed from the
# login-only case it was written against.
reset_arm
write_row 9000 0 10 none
if _auth_hold_active; then
    fail "F3 a 9000 s hold on an UNNAMED dialog (auth=none) outlived the 7200 s ceiling — the bound was only ever exercised on the login-labelled population"
else
    pass "F3 the hold ceiling bounds the WIDENED population too (unnamed dialog, auth=none, fails open at 9000 s)"
fi
# And the expiry row must be cleared by the knob, or liveness stays suppressed
# by a row nothing refreshes.
reset_arm
PROBE_REPLY="idle expired 111"; _auth_hold_observe orchestrator
MONITOR_AUTH_HOLD_ENABLED=false
_auth_hold_observe orchestrator
if _auth_hold_auth_expired orchestrator; then fail "F3 knob OFF left the expiry suppressing liveness"; else pass "F3 knob OFF clears the expiry row as well as the hold row"; fi
[[ -f "$(_auth_hold_expiry_path)" ]] && fail "F3 knob OFF left an expiry row on disk" || pass "F3 knob OFF removes the expiry row from disk"
unset MONITOR_AUTH_HOLD_ENABLED
rm -f "$(_auth_hold_expiry_path)"

# ---- D. the three clocks ------------------------------------------------


reset_arm; write_row 60 0 60
if _auth_hold_escape_due; then fail "D escape fired on a 60 s-old hold (threshold is 3600 s)"; else pass "D a fresh hold does NOT escape"; fi

# ISOLATING `escape_after` FROM `active_grace`. The assertion above does NOT do
# it, and a mutation round is how that was found: deleting the `escape_after`
# guard from `_auth_hold_escape_due` left the suite GREEN, because a pane that
# changed 60 s ago is already held back by the GRACE guard. So the assertion
# above reads as a test of the 3600 s threshold and is in fact a second test of
# the 300 s grace — two clocks, one of them unmeasured.
#
# A pane unchanged for 600 s CLEARS the grace (600 >= 300), so `escape_after` is
# the only guard left standing. Mutating it now reddens exactly here.
reset_arm; write_row 600 0 600
if _auth_hold_escape_due; then fail "D escape fired on a 600 s-old hold whose grace had already lapsed — the 3600 s escape_after threshold is not being applied"; else pass "D escape_after is applied INDEPENDENTLY of the grace (600 s old, grace lapsed, still held)"; fi

reset_arm; write_row 3700 0 3700
if _auth_hold_escape_due; then pass "D a 3700 s hold untouched for 3700 s ESCAPES (operator's ~1h)"; else fail "D a stale abandoned login did NOT escape"; fi

# THE AGEING AXIS, and it is the operator's explicit instruction. `last_observed`
# is refreshed every cycle; if the escape aged from THAT, the watcher's own
# 5 s probe would push its deadline away for ever and the board would never
# recover. Same row, same age, differing only in which field is fresh.
reset_arm; write_row 3700 0 3700
if _auth_hold_escape_due; then pass "D aged from FIRST HELD, not from the last observation (a fresh last_observed does not defer)"; else fail "D a fresh last_observed deferred the escape — aged from the wrong field"; fi

# The active-login deferral: same 3700 s hold, but the pane CHANGED 10 s ago.
reset_arm; write_row 3700 0 10
if _auth_hold_escape_due; then fail "D escape fired on an ACTIVELY-DRIVEN login (pane changed 10 s ago)"; else pass "D an actively-driven login DEFERS the escape (content_hash changed inside the grace)"; fi

# …and the deferral cannot compound: past the ceiling the hold is GONE, so
# `_auth_hold_escape_due` (which requires an active hold) is moot and the emit
# pastes. FAILS OPEN, which is the only safe polarity for a hold.
reset_arm; write_row 9000 0 10
if _auth_hold_active; then fail "D a 9000 s hold survived the 7200 s ceiling — an unbounded hold is #1517 rebuilt"; else pass "D the ceiling FAILS OPEN: past max_hold the hold releases whatever the pane says"; fi

# A stale observation releases too: the row is only as good as the last cycle
# that actually SAW the dialog.
reset_arm; write_row 1000 900 1000
if _auth_hold_active; then fail "D a hold with a 900 s-stale observation still held (staleness window is 600 s)"; else pass "D a STALE observation releases the hold"; fi

# Garbage in the row must release, not hold. Every form of not-knowing
# releases — the inverse of the kill-gate doctrine, and deliberately so.
for bad in 'dialog\tNaN\t0\t111\t0' 'over-limit\t1\t1\t1\t1' 'login\t1\t1\t1\t1' 'dialog' ''; do
    reset_arm
    printf "$bad\n" > "$row_path"
    if _auth_hold_active; then fail "D a malformed row ('$bad') HELD the board"; else pass "D a malformed row ('$bad') releases"; fi
done

# ISOLATING THE `kind` CHECK, same lesson as the escape_after isolation above and
# found the same way. Every row in the loop above carries stale or unparseable
# TIMESTAMPS, so the staleness guard refuses them all and the `kind` test is
# never what decides — deleting `[[ \$kind == login ]]` left the suite green.
# This row is FRESH and well-formed in every field except the kind, so the kind
# test is the only thing between it and a hold.
reset_arm
printf 'over-limit\t%s\t%s\t111\t%s\tnone\n' "$(( now - 60 ))" "$now" "$(( now - 60 ))" > "$row_path"
if _auth_hold_active; then fail "D a FRESH, well-formed row of the wrong KIND held the board — the kind check is not being applied, so another module's row could mute the operator's channel"; else pass "D the kind check is applied independently of staleness (a fresh non-login row does NOT hold)"; fi

# ---- E. delivered once after the escape --------------------------------
# The emit ladder is reproduced here in the SHAPE main.sh uses, and the
# assertion is about the LADDER's arithmetic: how many times does a body reach
# the paster across a hold, an escape and the cycle after it.
reset_arm
PASTES="$WORK/pastes"; : > "$PASTES"
fake_paste() { printf 'pasted\n' >> "$PASTES"; return 0; }
ladder() {   # one cycle
    if _auth_hold_active; then
        _auth_hold_record_held "archive-$1" emit
    else
        fake_paste
    fi
}
PROBE_REPLY="blocked login 111"; _auth_hold_observe orchestrator
ladder 1; ladder 2; ladder 3
assert_eq "E three cycles under an active hold paste NOTHING" "$(grep -c . "$PASTES")" 0
assert_eq "E …and all three are recorded in the held ledger, not dropped" \
    "$(grep -c $'\theld\t' "$(_auth_hold_held_log_path)")" 3
# Now the escape. `_auth_hold_escape` clears the row; the NEXT cycle pastes.
write_row 3700 0 3700
_tmux_pane_is_dead() { return 1; }          # live pane
resolve_window_id()  { printf 'orchestrator'; }
tmux() { return 0; }                         # accept the Escape keystroke
if _auth_hold_escape orchestrator; then pass "E the escape succeeds on a live pane"; else fail "E the escape failed on a live pane"; fi
ladder 4
assert_eq "E the held emit is delivered EXACTLY ONCE after the escape" "$(grep -c . "$PASTES")" 1
ladder 5
assert_eq "E …and the cycle after does not re-deliver it (no duplicate)" "$(grep -c . "$PASTES")" 2
grep -q 'ESCAPED' "$LOGCAP" && pass "E the escape is in the log" || fail "E no ESCAPED line"
grep -q 'login hold EXPIRED' "$ALERTCAP" && pass "E the operator is told the hold expired" || fail "E no expiry alert"

# ---- G(1). the #745 dead-pane guard precedes the Escape ----------------
# A write into a `remain-on-exit` corpse kills the tmux SERVER — the watcher,
# every worker and the operator's session. The guard is UNCONDITIONAL; only the
# WORDING branches (the #1020 shape), so BOTH readings must refuse.
reset_arm; write_row 3700 0 3700
TMUX_CALLS="$WORK/tmuxcalls"; : > "$TMUX_CALLS"
tmux() { printf '%s\n' "$*" >> "$TMUX_CALLS"; return 0; }
_tmux_pane_is_dead() { NEXUS_PANE_LIVE_VERDICT=dead; return 0; }
if _auth_hold_escape orchestrator; then fail "G the escape proceeded into a DEAD pane (#745: kills the tmux server)"; else pass "G the escape REFUSES a dead pane (#745)"; fi
assert_eq "G …and sent no keystroke at all" "$(grep -c . "$TMUX_CALLS")" 0
: > "$TMUX_CALLS"
_tmux_pane_is_dead() { NEXUS_PANE_LIVE_VERDICT=unknown; return 0; }
if _auth_hold_escape orchestrator; then fail "G the escape proceeded on an INDETERMINATE liveness reading (#1017/#1020: rc 0 means dead OR could-not-tell)"; else pass "G the escape refuses an indeterminate reading too — the refusal is unconditional, only the wording branches"; fi
assert_eq "G …and sent no keystroke there either" "$(grep -c . "$TMUX_CALLS")" 0
# And the guard being ABSENT must refuse, not proceed: a guard that did not run
# is not a pass (#991's lesson, and cch_setup's own rule).
: > "$TMUX_CALLS"
unset -f _tmux_pane_is_dead
if _auth_hold_escape orchestrator; then fail "G the escape proceeded with the #745 guard UNAVAILABLE"; else pass "G an unavailable #745 guard REFUSES the escape (a check that did not run is not a pass)"; fi
assert_eq "G …and sent no keystroke" "$(grep -c . "$TMUX_CALLS")" 0
_tmux_pane_is_dead() { return 1; }

# ---- G(2). the knob OFF restores current behaviour exactly -------------
reset_arm
MONITOR_AUTH_HOLD_ENABLED=false
PROBE_REPLY="blocked login 111"
_auth_hold_observe orchestrator
if _auth_hold_active; then fail "G(2) the hold engaged with the knob OFF"; else pass "G(2) knob OFF: no hold, whatever the pane shows"; fi
[[ -f "$row_path" ]] && fail "G(2) knob OFF still wrote a hold row" || pass "G(2) knob OFF writes no state at all"
assert_eq "G(2) knob OFF notifies nobody" "$(grep -c . "$ALERTCAP")" 0
if _auth_hold_escape_due; then fail "G(2) knob OFF still reported an escape due"; else pass "G(2) knob OFF: no escape"; fi

# ISOLATING THE KNOB GUARD INSIDE `_auth_hold_active`, found by the same
# mutation round as the two isolations in part D: deleting
# `_auth_hold_enabled || return 1` from `_auth_hold_active` left the suite
# GREEN, because every knob-OFF assertion above reaches `_auth_hold_active`
# through `_auth_hold_observe`, which has its OWN knob guard and clears the row
# — so the gate's guard was never the thing deciding.
#
# The scenario it actually protects is real and is not exotic: THE OPERATOR
# FLIPS THE KNOB OFF WHILE A HOLD IS LIVE. A row is already on disk, and the
# emit ladder can consult `_auth_hold_active` before the 5 s `auth_hold` task
# next runs and clears it. Without the guard the board stays muted after the
# operator has explicitly disabled the feature — the one state in which they
# are entitled to assume it cannot be the cause.
MONITOR_AUTH_HOLD_ENABLED=true
reset_arm
PROBE_REPLY="blocked login 111"; _auth_hold_observe orchestrator
_auth_hold_active || fail "G(2) fixture: could not establish a live hold to turn the knob off under"
MONITOR_AUTH_HOLD_ENABLED=false
if _auth_hold_active; then fail "G(2) a hold row written BEFORE the knob was turned off still holds — flipping the knob off does not take effect until the next observe, so the board stays muted after the operator disabled the feature"; else pass "G(2) knob OFF releases an ALREADY-WRITTEN hold row immediately, without waiting for the next observe"; fi
if _auth_hold_escape_due; then fail "G(2) knob OFF with a live row still reported an escape due"; else pass "G(2) knob OFF with a live row: no escape either"; fi
if _auth_hold_auth_expired orchestrator; then fail "G(2) knob OFF still reported auth expired"; else pass "G(2) knob OFF: the liveness gate is inert too"; fi
_auth_hold_step orchestrator
pass "G(2) _auth_hold_step is a no-op with the knob OFF (returned $?)"
unset MONITOR_AUTH_HOLD_ENABLED

# ---- F. liveness files no resubmit and no respawn ----------------------
# Drives the REAL `_orchestrator_auth_blocked` and the REAL
# `_orchestrator_liveness_decide`. The verdict is what gates the resubmit and
# the respawn upstream, so asserting the verdict is asserting the remedy.
reset_arm
# shellcheck source=_orchestrator_liveness.sh
source "$_test_dir/_orchestrator_liveness.sh" 2>/dev/null \
    || env_fail "could not source _orchestrator_liveness.sh (it is a pre-existing module; a failure to source it is about the machine)"
# Same rule as above: the GATE being absent is the `#1517` regression, not an
# environment fault.
if ! declare -F _orchestrator_auth_blocked >/dev/null 2>&1; then
    fail "_orchestrator_auth_blocked is undefined — orchestrator-liveness has NO auth gate, so a logged-out orchestrator is still read as a lost paste: #1517's 8 resubmits, 10 false 'recovered' lines and 0 log lines naming auth."
    th_summary_and_exit
fi

TARGET=orchestrator
PROBE_REPLY="blocked login 111"; _auth_hold_observe orchestrator
if _orchestrator_auth_blocked; then
    assert_eq "F a live hold is an auth block of kind 'hold'" "$ORCH_AUTH_BLOCK_KIND" hold
else
    fail "F a live login hold did not register as an auth block"
fi

# The #1517 surface proper: NO hold (no dialog is up), the session is simply
# logged out and idle. This is the exact state that drew 8 resubmits.
reset_arm
PROBE_REPLY="idle expired 111"; _auth_hold_observe orchestrator
if _auth_hold_active; then fail "F auth=expired engaged the emit HOLD — it must not: pasting into a logged-out idle REPL is harmless and the operator needs the board state waiting for them"; else pass "F auth=expired does NOT hold the emit (only liveness is gated)"; fi
if _orchestrator_auth_blocked; then
    assert_eq "F a logged-out session is an auth block of kind 'expired'" "$ORCH_AUTH_BLOCK_KIND" expired
else
    fail "F #1517's exact state (auth=expired, no dialog) did not register as an auth block"
fi

# Now the verdict. Build the file substrate the decider reads, with a paste old
# enough to be past grace and inside the ceiling — i.e. the precise window in
# which `#1517` resubmitted.
hb="$WORK/hb"; pr="$WORK/pr"; lp="$WORK/lp"; pin="$WORK/pin"; us="$WORK/us"; rm_="$WORK/rm"
printf '%s\n' "$(( now - 600 ))" > "$lp"
decide() {
    _orchestrator_liveness_decide "$hb" "$pr" "$lp" "$pin" "$us" "$rm_" \
        120 150 300 1800 "$REPO_ROOT" "$WORK/home" 2>/dev/null
}
verdict=$(decide); rc=$?
if [[ "$verdict" == healthy*auth-expired* ]]; then
    pass "F the verdict is 'auth-expired', so no resubmit and no respawn fire: $verdict"
else
    fail "F verdict did not name the auth block (got: '$verdict') — #1517 is reproduced: 8 resubmits and 10 false 'recovered' lines over 45 h, with 'auth' in NONE of 1,648 log lines"
fi
assert_eq "F …and the verdict's rc is 1 (no action), not an escalation" "$rc" 1
grep -qi 'auth' <<<"$verdict" \
    && pass "F the verdict text contains 'auth' — the word #1517 could not find anywhere in the log" \
    || fail "F the verdict text does not mention auth"

# NEGATIVE CONTROL for F, and it is the one that makes the rest of F mean
# something: with no auth surface at all, the decider must NOT return the auth
# verdict. A gate that fires unconditionally would pass every assertion above
# while disabling wedge detection entirely.
reset_arm
PROBE_REPLY="idle none 111"; _auth_hold_observe orchestrator
if _orchestrator_auth_blocked; then
    fail "F/neg a healthy pane registered as an auth block — wedge detection is now disabled for every orchestrator"
else
    pass "F/neg a healthy pane is NOT an auth block"
fi
verdict2=$(decide)
if [[ "$verdict2" == *auth-* ]]; then
    fail "F/neg the decider returned an auth verdict for a healthy pane (got: '$verdict2')"
else
    pass "F/neg a healthy pane reaches the ordinary ladder, not the auth gate (got: '$verdict2')"
fi

# EXPECTED-COUNT GUARD. Derived from the parts rather than pinned to a literal,
# so adding a case to a part updates one number next to that part's name instead
# of drifting silently. It exists because an assertion that never EXECUTED is
# invisible in a pass/fail tally — and three of this suite's parts are inside
# loops or conditionals, which is exactly where a case goes missing.
#
# A  16  4 login-frame (2 fixtures x state/auth/overlay = 6) + 4 expired
#        (2 x state/auth) + 4 negative-control auth + 2 overlay-unchanged
# B   2  reworded-login state + the auth-honesty report
# C0  5  index keying x2, liveness keying, degraded-path key, degraded hold
# C  10  engage/log/alert/once, quoted-frame, release/log, unreadable x2
# D  14  fresh, stale-escape, aged-from-first, isolate-escape_after, grace,
#        ceiling, stale-observation, 4 malformed rows, kind-isolation  (+1 each
#        for the two isolation assertions added after the mutation round)
# E   7  three held cycles, ledger=3, escape ok, once, no-duplicate, 2 log/alert
# G   9  dead-pane x2, indeterminate x2, guard-absent x2, (G2) 7 knob-off
# F   8  hold kind, expired-no-hold, expired kind, verdict, rc, auth-in-text,
#        2 negative controls
# F1 13  reworded-holds, label=none, notify-says-unknown, 4 dialog classes,
#        5 non-blocked states that must NOT hold  (w237sk F1)
# F3  6  fresh suppresses, ceiling fails open, log names it, WIDENED-population
#        ceiling, knob clears expiry, knob removes the row  (w237sk F3)
# D1  5  three arm-naming statements, the labelled-only exposure, and a NEG that
#        the superseded unconditional claim is GONE  (w237sk D1)
# D2  8  splice preconditions x2, busy-not-labelled, hold-acts-by-design,
#        3 direction assertions on real login captures, list completeness + wired
EXPECTED=120
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
