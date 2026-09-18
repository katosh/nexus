#!/usr/bin/env bash
# test-tmux-window-resolver.sh — the THREE-STATE window-resolution contract
# (your-org/nexus-code#699).
#
# WHAT IS UNDER TEST. `resolve_window_id` / `resolve_window_index` used to
# return rc 1 for four operationally distinct situations — no tmux binary, a
# failed `list-windows`, an empty name, and a genuine absence — with
# `2>/dev/null` swallowing the reason. Any consumer whose non-zero arm is
# PERMISSIVE then acts irreversibly on a window it never observed. `ng
# retire-window` did exactly that: rc 1 → empty wid → its own preflight gate
# skipped → state pruned for a window that may have been alive (#646, one
# layer down).
#
# THE ASYMMETRY THIS SUITE EXISTS TO HOLD. A change that only widens refusal
# is not a fix — it breaks ordinary retirement, which is the far more common
# path. So every "refuses" assertion here is paired with a CONTROL asserting
# the ordinary path still completes. Parts B3/B4 are those controls; if a
# future edit makes the resolver pessimistic, they redden, not A.
#
# WHY THE POSITIVE ARMS NEED A REAL SERVER. rc 0 and rc 1 can only be
# distinguished by a tmux that actually answers. We stand up a PRIVATE server
# under `env -u TMUX TMUX_TMPDIR=<dir>` — `$TMUX` outranks `TMUX_TMPDIR`, so
# unsetting it is what makes the isolation real (your-org/nexus-code#644) —
# and never touch the ambient server. `tmux -L` is not used: the resolvers
# call bare `tmux`, so the seam has to be the default socket inside a private
# TMUX_TMPDIR, which is what the production code would see.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON=$(cd "$_test_dir/.." && pwd)
HELPER="$MON/_tmux-window.sh"
NG_REAL="$MON/ng"
[[ -f "$HELPER" ]] || { echo "helper not found: $HELPER" >&2; exit 1; }

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
#
# THE FILE SET EVERY SOURCE-SCANNING PART OF THIS SUITE READS: production shell
# under `monitor/`. D1 (the resolver manifest) enumerates it twice, by NAME and
# by BEHAVIOUR; F1 (`delim_violations`) greps the same set for tmux format
# strings.
#
# `_axis_behaviour` CONSUMES this function, so for that scan the declared
# population is the enumerator itself and cannot drift from it. `_axis_name`
# and `delim_violations` reach the same set through their own recursive greps,
# which are built around `-a`/binary-detection and `--include` behaviour that
# is load-bearing for what they do — so they are left alone, and the honest
# statement is that this declaration is EQUAL to their set today rather than
# derived from it. Narrowing either recursion's filter without narrowing this
# function would leave the declaration WIDER than the truth, which over-selects
# (the safe direction). Widening one without widening this would under-select,
# which is the direction that matters; that is the one drift a reader of this
# suite has to hold, and it is named here rather than discovered later.
#
# Declared this early on purpose: `gp_handle` must answer BEFORE the suite
# stands up its private tmux server, or a population probe would cost a server
# boot and could fail on a host with no tmux at all.
#
# This is `#803`'s third occurrence, from the other side. PR `#796` added a
# `tmux list-windows -F` with a literal TAB and a new name->window resolver, ran
# the suites it authored and the ones it touched, and reddened THIS one — which
# it never ran, because nothing mapped its diff to this population.
_resolver_scan_files() {   # -> production shell under monitor/, NUL-free tree
    find "$MON" -name '*.sh' -not -path '*/test*' 2>/dev/null | sort
}
. "$MON/_guard_population.sh"
gp_population() {
    _resolver_scan_files
    printf '%s\n' "$HELPER"
}
gp_handle "$@"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n           expected: %s\n           in: %s\n' \
               "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n           in: %s\n' \
            "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}
assert_matches() {
    local label="$1" got="$2" re="$3"
    if [[ -z "$re" ]]; then
        printf '  FAIL: %s — EMPTY regex: `[[ $x =~ "" ]]` matches every string, so\n' "$label" >&2
        printf '         this assertion could only have passed VACUOUSLY (your-org/nexus-code#1110).\n' >&2
        printf '         Fix the CALLER, not the haystack: its expected pattern came back empty.\n' >&2
        printf '         Check the rc of whatever produced it (a capture that failed prints\n' >&2
        printf '         nothing, and an unconsulted rc turns that into a silent pass).\n' >&2
        FAIL=$(( FAIL + 1 ))
        return
    fi
    if [[ "$got" =~ $re ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — %q does not match /%s/\n' "$label" "$got" "$re" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# A short WORK dir is mandatory, not cosmetic: a tmux socket path lives under
# TMUX_TMPDIR and a long one fails with "File name too long" — which would
# make the rc-0/rc-1 arms below silently take the rc-3 path and pass for the
# wrong reason. mktemp honours TMPDIR, so pin it.
WORK=$(TMPDIR=/tmp mktemp -d)
PRIV="$WORK/tm"; mkdir -p "$PRIV"
# A PATH with the ordinary toolchain but NO tmux. Symlinking a curated set is
# the only honest way to get `command -v tmux` to fail: an actually-empty dir
# also removes `bash`, so the probe dies rc 127 and the assertion passes for
# the wrong reason — which is exactly what the first cut of this suite did.
EMPTYBIN="$WORK/emptybin"; mkdir -p "$EMPTYBIN"
for _b in bash sh cat date awk sed grep printf tr cut sort head tail mktemp rm mkdir wc stat; do
    _p=$(command -v "$_b" 2>/dev/null) && ln -sf "$_p" "$EMPTYBIN/$_b"
done
command -v tmux >/dev/null 2>&1 || { echo "SETUP: tmux not installed; this suite needs it" >&2; exit 1; }
[[ -e "$EMPTYBIN/tmux" ]] && { echo "SETUP FAILED: tmux leaked into the no-tmux PATH" >&2; exit 1; }
PATH="$EMPTYBIN" command -v tmux >/dev/null 2>&1 \
    && { echo "SETUP FAILED: tmux still resolvable on the no-tmux PATH" >&2; exit 1; }
PATH="$EMPTYBIN" command -v bash >/dev/null 2>&1 \
    || { echo "SETUP FAILED: bash NOT resolvable on the no-tmux PATH — the no-tmux arms would pass as rc 127" >&2; exit 1; }
NOSRV="$WORK/nosrv"; mkdir -p "$NOSRV"
PRESENT_WIN=zz-699-present

cleanup() {
    # kill-SESSION, targeted, never kill-server. Ending a tmux server ends the
    # session bwrap holds open and tears down the whole sandbox
    # (your-org/nexus-code#644), and `env -u TMUX` alone is explicitly NOT
    # accepted as scoping for kill-server — the repo's own lint enforces that
    # bright line and caught the first cut of this file. Killing the fixture's
    # only session retires its private server anyway, so nothing leaks.
    env -u TMUX TMUX_TMPDIR="$PRIV" tmux kill-session -t s699 >/dev/null 2>&1 || true
    # Part I adds a SECOND session on the same private server; retiring only
    # the first would leave the server (and its socket) behind.
    env -u TMUX TMUX_TMPDIR="$PRIV" tmux kill-session -t zz-944-other >/dev/null 2>&1 || true
    # Part J adds a THIRD session (your-org/nexus-code#1318) — a cross-session
    # name/index collision needs a session the collision is NOT in.
    env -u TMUX TMUX_TMPDIR="$PRIV" tmux kill-session -t zz-1318-name >/dev/null 2>&1 || true
    env -u TMUX TMUX_TMPDIR="$PRIV" tmux kill-session -t zz-1318-clean >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# tmux present + a live private server.
srv() { env -u TMUX TMUX_TMPDIR="$PRIV" "$@"; }
# tmux present, NO server reachable (empty socket dir).
nosrv() { env -u TMUX TMUX_TMPDIR="$NOSRV" "$@"; }
# tmux ABSENT from PATH entirely.
notmux() { env -u TMUX PATH="$EMPTYBIN" "$@"; }

# `rc<TAB>stdout<TAB>stderr` — stdout and stderr captured SEPARATELY, because
# half of what this contract adds is a diagnostic on stderr, and merging them
# would let a missing diagnostic pass.
run3() {
    local out err rc=0
    err="$WORK/err.$$"
    out=$("$@" 2>"$err") || rc=$?
    printf '%s\t%s\t%s' "$rc" "$out" "$(cat "$err")"
}
f_rc()  { printf '%s' "${1%%$'\t'*}"; }
f_out() { local r="${1#*$'\t'}"; printf '%s' "${r%%$'\t'*}"; }
f_err() { printf '%s' "${1##*$'\t'}"; }

srv tmux new-session -d -s s699 -n "$PRESENT_WIN" 2>/dev/null \
    || { echo "SETUP FAILED: could not start a private tmux server in $PRIV" >&2; exit 1; }

# tmux renames a window to whatever command is running in it, a short moment
# after the shell settles. That is a RACE against a name-keyed suite: the
# early assertions saw `zz-699-present` and the later ones saw `bash`, so the
# rc-0 arms failed intermittently while the rc-1/rc-3 arms passed — the
# signature of a fixture decaying mid-run, not of a broken contract. The
# watcher disables both options for the same reason (_respawn.sh). Setting
# them is not enough on its own; the check below is what makes the fixture's
# stability an ASSERTION rather than an assumption.
srv tmux set-option  -g automatic-rename off >/dev/null 2>&1 || true
srv tmux set-option  -g allow-rename     off >/dev/null 2>&1 || true
srv tmux set-window-option -t s699: automatic-rename off >/dev/null 2>&1 || true
_seen=$(srv tmux list-windows -t s699: -F '#{window_name}' 2>/dev/null | head -1)
[[ "$_seen" == "$PRESENT_WIN" ]] || {
    echo "SETUP FAILED: fixture window is named '$_seen', expected '$PRESENT_WIN' — automatic-rename is still active; every rc-0 assertion below would be meaningless" >&2
    exit 1
}

# =====================================================================
# Part A — the resolver contract, all four arms, both resolvers
# =====================================================================

echo '=== A: resolve_window_id / resolve_window_index — four states ==='

# A1 — no tmux binary at all. Was rc 1 "absent"; the machine cannot host a
# window it has no tmux for, and inferring absence from that is the bug.
r=$(run3 notmux bash "$HELPER" id "$PRESENT_WIN")
assert_eq       "A1 no-tmux: rc 3 (could not look)" "$(f_rc "$r")" 3
assert_contains "A1 no-tmux: says UNKNOWN, not absent" "$(f_err "$r")" "UNKNOWN, not absent"

# A2 — THE OPERATIONALLY LIKELY ONE. tmux is installed, the server is not
# reachable. Previously rc 1 with COMPLETE SILENCE: `2>/dev/null` ate the
# reason, so the caller could not have distinguished it even if it wanted to.
r=$(run3 nosrv bash "$HELPER" id "$PRESENT_WIN")
assert_eq       "A2 no-server: rc 3 (could not look)" "$(f_rc "$r")" 3
assert_contains "A2 no-server: surfaces tmux's own reason" "$(f_err "$r")" "list-windows failed"
assert_not_contains "A2 no-server: does NOT print an id" "$(f_out "$r")" "@"

# A3 — the empty name. Nothing was asked, so "absent" would be fabricated.
r=$(run3 srv bash "$HELPER" id "")
assert_eq       "A3 empty-name: rc 2 (cannot ask)" "$(f_rc "$r")" 2
assert_contains "A3 empty-name: names the caller bug" "$(f_err "$r")" "EMPTY window name"

# A4 — CONTROL. tmux answers, the window is genuinely not there. This is the
# ONLY non-zero rc that a consumer may treat as "gone".
r=$(run3 srv bash "$HELPER" id zz-699-definitely-absent)
assert_eq "A4 absent: rc 1 (looked, and absent)" "$(f_rc "$r")" 1
assert_eq "A4 absent: no diagnostic (it is not an error)" "$(f_err "$r")" ""

# A5 — CONTROL. The window is present; ordinary resolution still works.
r=$(run3 srv bash "$HELPER" id "$PRESENT_WIN")
assert_eq      "A5 present: rc 0" "$(f_rc "$r")" 0
assert_matches "A5 present: prints an @id" "$(f_out "$r")" '^@[0-9]+$'

# A6-A9 — resolve_window_index carries the SAME contract. Asserted
# independently rather than assumed: it is a separate function body, and the
# whole defect class here is one copy being fixed while its twin is not.
r=$(run3 notmux bash "$HELPER" index "$PRESENT_WIN")
assert_eq "A6 index no-tmux: rc 3" "$(f_rc "$r")" 3
r=$(run3 nosrv bash "$HELPER" index "$PRESENT_WIN")
assert_eq "A7 index no-server: rc 3" "$(f_rc "$r")" 3
r=$(run3 srv bash "$HELPER" index zz-699-definitely-absent)
assert_eq "A8 index absent: rc 1" "$(f_rc "$r")" 1
r=$(run3 srv bash "$HELPER" index "$PRESENT_WIN")
assert_eq      "A9 index present: rc 0" "$(f_rc "$r")" 0
assert_matches "A9 index present: prints an integer" "$(f_out "$r")" '^[0-9]+$'

# A10 — exact, full-field match. A prefix match would make `worker` resolve
# to `worker-2` and target the wrong pane; pinned here because the rewrite
# changed the read loop.
srv tmux new-window -d -t s699: -n "${PRESENT_WIN}-suffix" 2>/dev/null || true
r=$(run3 srv bash "$HELPER" id "$PRESENT_WIN")
id_exact=$(f_out "$r")
r2=$(run3 srv bash "$HELPER" id "${PRESENT_WIN}-suffix")
assert_not_contains "A10 exact match: prefix does not collide" "$id_exact" "$(f_out "$r2")"

# =====================================================================
# Part E — LOCALE. A present window must not read as absent.
# =====================================================================
#
# Found by this suite failing under `LC_ALL=C` while green otherwise. Under a
# C/POSIX locale tmux rewrites a TAB in `-F` output as `_`, so the old
# TAB-delimited split never separated, no name ever matched, and the resolver
# returned rc 1 — "looked, and ABSENT" — for a window that was right there.
# On the pre-#699 two-valued contract that made `ng retire-window` skip its
# preflight and prune a LIVE window's state, triggered by nothing more exotic
# than the locale a cron or systemd unit runs under.
#
# This is the sharper half of the class: not "could not look" sold as
# absence, but a WRONG ANSWER sold as absence. Measured on tmux 2.6 (the
# repo's floor); asserted here for whatever tmux the runner has, in both
# directions, so a future delimiter change cannot quietly reintroduce it.

echo
echo '=== E: a present window resolves under a C/POSIX locale ==='

c_srv() { env -u TMUX LC_ALL=C TMUX_TMPDIR="$PRIV" "$@"; }
p_srv() { env -u TMUX LC_ALL=POSIX TMUX_TMPDIR="$PRIV" "$@"; }

r=$(run3 c_srv bash "$HELPER" id "$PRESENT_WIN")
assert_eq      "E1 LC_ALL=C: present window still resolves (rc 0)" "$(f_rc "$r")" 0
assert_matches "E1 LC_ALL=C: and yields a real @id" "$(f_out "$r")" '^@[0-9]+$'
r=$(run3 c_srv bash "$HELPER" index "$PRESENT_WIN")
assert_eq "E2 LC_ALL=C: index resolves too" "$(f_rc "$r")" 0
r=$(run3 p_srv bash "$HELPER" id "$PRESENT_WIN")
assert_eq "E3 LC_ALL=POSIX: present window still resolves" "$(f_rc "$r")" 0
# CONTROL — the C locale must not make everything resolve either.
r=$(run3 c_srv bash "$HELPER" id zz-699-definitely-absent)
assert_eq "E4 CONTROL LC_ALL=C: a genuinely absent window is still rc 1" "$(f_rc "$r")" 1

# E5 — the belt. If the delimiter is EVER defeated again (a new locale quirk,
# a tmux change, a format edit), an unsplittable row must surface as rc 3
# "could not look", never as rc 1 "absent". Driven with a stub tmux that
# returns success and an unparseable row — the exact shape the C locale used
# to produce.
STUBBIN="$WORK/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/tmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "list-windows" ]] || exit 0
printf '@0_zz-699-present\n'   # delimiter eaten, exactly as LC_ALL=C did
exit 0
STUB
chmod +x "$STUBBIN/tmux"
r=$(run3 env -u TMUX PATH="$STUBBIN:$EMPTYBIN" bash "$HELPER" id zz-699-present)
assert_eq       "E5 mangled row: rc 3 (could not look), NOT rc 1" "$(f_rc "$r")" 3
assert_contains "E5 mangled row: says presence is UNKNOWN" "$(f_err "$r")" "UNKNOWN, not absent"

# =====================================================================
# Part B — the consumer that acts irreversibly: ng retire-window
# =====================================================================
#
# The contract only matters if a consumer honours it. B1/B2 assert the
# refusal AND that nothing was pruned; B3/B4 are the controls that keep the
# fix from degenerating into "always refuse".

echo
echo '=== B: ng retire-window honours the contract ==='

FAKE="$WORK/nexus"
build_tree() {
    rm -rf "$FAKE"
    mkdir -p "$FAKE/monitor/.state" "$FAKE/config" "$FAKE/reports"
    # THE SUITE OWNS ARM 1 (your-org/nexus-code#1386). `ng` resolves its state
    # dir NEXUS_STATE_DIR -> NEXUS_ROOT/monitor/.state -> …, and arm 1 is the
    # only unconditional one — so an AMBIENT pin in the caller's shell (the
    # very remedy #1349 prescribes for ad-hoc tooling) silently overrode the
    # fixture this function builds: retire-window pruned the pin instead of
    # $FAKE/monitor/.state, B3/B4 read "state was NOT pruned", and the red was
    # indistinguishable from a defect in the reader's own diff (93/0 -> 91/2,
    # one variable). A suite that arranges its own state dir names it in the
    # variable that cannot be fallen past, so nothing ambient can win.
    export NEXUS_STATE_DIR="$FAKE/monitor/.state"
    cp "$NG_REAL" "$FAKE/monitor/ng"
    cp "$MON/_bookkeeping.sh" "$FAKE/monitor/_bookkeeping.sh"
    # your-org/nexus-code#1077 — `ng` refuses to start without the primary-root
    # resolver, for the same reason it refuses without `_bookkeeping.sh`: a
    # silent un-pinning of reports and assets from the primary clone is worse
    # than a refusal. Omitting it here would test `ng`'s behaviour with a broken
    # install, which is a different question from the one B1-B5 ask.
    cp "$MON/_nexus-root.sh" "$FAKE/monitor/_nexus-root.sh"
    cp "$HELPER" "$FAKE/monitor/_tmux-window.sh"
    # your-org/nexus-code#977 — `retire-window` now runs the preflight on the
    # ABSENT path too (checks 1b/1c are obligation checks, not liveness
    # checks), so the gate is a real dependency of every arm below rather
    # than of the present-window arm only. Omitting it here made B3/B4 test
    # `ng`'s behaviour when its own gate is missing, which is a different
    # question and is now covered explicitly by that verb's own precondition.
    cp "$MON/retire-preflight.sh" "$FAKE/monitor/retire-preflight.sh"
    cp "$MON/_obligations.sh"     "$FAKE/monitor/_obligations.sh"
    chmod +x "$FAKE/monitor/ng" "$FAKE/monitor/retire-preflight.sh"
    cat > "$FAKE/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)       printf 'org/repo' ;;
    github.user_login) printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$FAKE/config/load.sh"
    # A state surface that NAMES the window. Without it, "did not prune" is
    # unfalsifiable — there would be nothing to prune either way, and B1
    # would pass against a verb that pruned everything it could find.
    printf '%s\t%s\t%s\n' "$1" "$(date +%s)" "idle" > "$FAKE/monitor/.state/idle-state.tsv"
}
state_mentions() { grep -qF -- "$1" "$FAKE/monitor/.state/idle-state.tsv" 2>/dev/null; }

VICTIM=zz-699-victim

# B1 — server unreachable. MUST refuse, and MUST leave the state alone.
build_tree "$VICTIM"
r=$(run3 nosrv env NEXUS_ROOT="$FAKE" NEXUS_WORKER_WINDOW="" bash "$FAKE/monitor/ng" retire-window "$VICTIM")
assert_matches  "B1 no-server: retire-window exits non-zero" "$(f_rc "$r")" '^[1-9]'
assert_contains "B1 no-server: refuses in the issue's terms" "$(f_err "$r")" "NOT an absent window"
if state_mentions "$VICTIM"; then
    printf '  PASS: %s\n' "B1 no-server: state was NOT pruned"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "B1 no-server: state WAS pruned for an unobserved window" >&2; FAIL=$(( FAIL + 1 ))
fi

# B2 — no tmux binary. Same refusal; this is the arm the removed
# `if command -v tmux` wrapper used to launder into a silent prune.
build_tree "$VICTIM"
r=$(run3 notmux env NEXUS_ROOT="$FAKE" NEXUS_WORKER_WINDOW="" bash "$FAKE/monitor/ng" retire-window "$VICTIM")
assert_matches "B2 no-tmux: retire-window exits non-zero" "$(f_rc "$r")" '^[1-9]'
if state_mentions "$VICTIM"; then
    printf '  PASS: %s\n' "B2 no-tmux: state was NOT pruned"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "B2 no-tmux: state WAS pruned for an unobserved window" >&2; FAIL=$(( FAIL + 1 ))
fi

# B3 — CONTROL, and the one that keeps this honest. tmux ANSWERS and says the
# window is not there. Ordinary retirement must still complete and prune,
# exactly as before the change.
build_tree "$VICTIM"
r=$(run3 srv env NEXUS_ROOT="$FAKE" NEXUS_WORKER_WINDOW="" bash "$FAKE/monitor/ng" retire-window "$VICTIM")
assert_eq       "B3 CONTROL absent: retire-window succeeds" "$(f_rc "$r")" 0
assert_contains "B3 CONTROL absent: reports the retirement" "$(f_out "$r")" "retired"
if state_mentions "$VICTIM"; then
    printf '  FAIL: %s\n' "B3 CONTROL absent: state was NOT pruned (fix is over-refusing)" >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: %s\n' "B3 CONTROL absent: state was pruned"; PASS=$(( PASS + 1 ))
fi

# B4 — the deliberate override. An operator who KNOWS the server is gone can
# still prune; the point of the fix is that this is an assertion, not an
# inference. Paired with B1: same environment, opposite outcome, one flag.
build_tree "$VICTIM"
r=$(run3 nosrv env NEXUS_ROOT="$FAKE" NEXUS_WORKER_WINDOW="" bash "$FAKE/monitor/ng" retire-window "$VICTIM" --assume-absent)
assert_eq       "B4 --assume-absent: succeeds where B1 refused" "$(f_rc "$r")" 0
assert_contains "B4 --assume-absent: warns that it could not observe" "$(f_err "$r")" "could not observe tmux"
if state_mentions "$VICTIM"; then
    printf '  FAIL: %s\n' "B4 --assume-absent: state was NOT pruned" >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: %s\n' "B4 --assume-absent: state was pruned"; PASS=$(( PASS + 1 ))
fi

# B5 — the GATE ITSELF IS MISSING (your-org/nexus-code#977). `retire-window`
# is gate-then-prune, and since #977 the gate runs on the ABSENT path too. So
# an unrunnable gate must refuse and say what is missing — not leak a bare
# `rc 127` from a command substitution, and above all not prune.
#
# This arm exists because the omission was INVISIBLE before #977: the absent
# path skipped the preflight entirely, so a fake tree without
# `retire-preflight.sh` retired windows happily and nothing anywhere said the
# gate had never been consulted. Same shape as the defect #977 fixes, one
# level down — a check that is not run leaves the same trace as a check that
# passed.
build_tree "$VICTIM"
rm -f "$FAKE/monitor/retire-preflight.sh"
r=$(run3 srv env NEXUS_ROOT="$FAKE" NEXUS_WORKER_WINDOW="" bash "$FAKE/monitor/ng" retire-window "$VICTIM")
assert_matches  "B5 missing gate: retire-window exits non-zero" "$(f_rc "$r")" '^[1-9]'
assert_contains "B5 missing gate: names the script that is missing" \
    "$(f_err "$r")" "retire-preflight.sh not found or not executable"
assert_contains "B5 missing gate: says WHY that forbids the prune" \
    "$(f_err "$r")" "no safe prune to perform"
if state_mentions "$VICTIM"; then
    printf '  PASS: %s\n' "B5 missing gate: state was NOT pruned"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "B5 missing gate: state WAS pruned with no gate at all" >&2; FAIL=$(( FAIL + 1 ))
fi

# =====================================================================
# Part C — the second live instance: _over_limit_resolve_window_index
# =====================================================================
#
# A separate implementation of the same shape in monitor/watcher/_over_limit.sh.
# It returned rc 0 with EMPTY stdout for every failure, and the wake path read
# empty as absence and DROPPED the over-limit stamp — logging the word
# "absent" about a window it had never observed.

echo
echo '=== C: _over_limit_resolve_window_index carries the same contract ==='

ol_probe() {  # ol_probe <env-fn> <name> — rc of the resolver, in isolation
    local envfn="$1" name="$2"
    "$envfn" bash -c '
        set -uo pipefail
        . "$1" 2>/dev/null
        _over_limit_resolve_window_index "$2" >/dev/null
    ' _ "$MON/watcher/_over_limit.sh" "$name"
    printf '%s' "$?"
}

assert_eq "C1 no-tmux: rc 3 (could not look)"      "$(ol_probe notmux "$PRESENT_WIN")" 3
assert_eq "C2 no-server: rc 3 (could not look)"    "$(ol_probe nosrv  "$PRESENT_WIN")" 3
assert_eq "C3 CONTROL absent: rc 1"                "$(ol_probe srv    zz-699-definitely-absent)" 1
assert_eq "C4 CONTROL present: rc 0"               "$(ol_probe srv    "$PRESENT_WIN")" 0

# C5/C6 — the wake path itself, BEHAVIOURALLY. An earlier cut of this checked
# only that the hold branch appeared before the drop branch in the source; that
# assertion SURVIVED its own mutant (blanking the guard condition leaves both
# strings in place, in order), so it asserted the text and not the rule. This
# drives the real `_over_limit_evaluate_row` and looks at what happened to the
# stamp — the only thing that actually matters.
ol_wake() {  # ol_wake <env-fn> <window> — prints "<log>|<stamp-present>"
    local envfn="$1" window="$2"
    "$envfn" bash -c '
        set -uo pipefail
        export STATE_DIR="$3"
        mkdir -p "$STATE_DIR"
        _over_limit_log_capture() { printf "%s\n" "$*" >> "$STATE_DIR/log"; }
        _OVER_LIMIT_LOG_FN=_over_limit_log_capture
        . "$1" 2>/dev/null
        _OVER_LIMIT_LOG_FN=_over_limit_log_capture
        now=1900000000
        path=$(_over_limit_state_path)
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            _orchestrator "$2" orchestrator tok \
            $(( now + 3600 )) $(( now - 60 )) $(( now - 1 )) 0 > "$path"
        _over_limit_evaluate_row "$(cat "$path")" "$now" >/dev/null 2>&1
        printf "%s|%s" \
            "$(tr "\n" " " < "$STATE_DIR/log" 2>/dev/null)" \
            "$(grep -qc _orchestrator "$path" 2>/dev/null && echo present || echo gone)"
    ' _ "$MON/watcher/_over_limit.sh" "$window" "$WORK/ol.$RANDOM$$"
}

# C5 — COULD NOT LOOK. The stamp must survive: dropping it retires a hold for
# a window never observed, and if that window is still frozen every later emit
# piles into a dead pane with nothing left to say so.
r=$(ol_wake nosrv "$PRESENT_WIN")
assert_contains "C5 wake could-not-look: logs a HOLD, not an absence" "${r%|*}" "holding the stamp"
assert_eq       "C5 wake could-not-look: stamp SURVIVES" "${r##*|}" "present"

# C6 — CONTROL. tmux answers and the window really is gone: the stamp must
# still be dropped, exactly as before. Without this, C5 passes against a wake
# path that never drops anything.
r=$(ol_wake srv zz-699-definitely-absent)
assert_contains "C6 CONTROL wake absent: logs the drop" "${r%|*}" "absent at wake"
assert_eq       "C6 CONTROL wake absent: stamp is dropped" "${r##*|}" "gone"

# C7/C8 — THE BELT, on the twin that #699 forgot (your-org/nexus-code#701 item
# C). `#699` gave `_tmux_window_check_row` to resolve_window_id/_index and not
# to this function, which it rewrote in the SAME commit and declared to carry
# "the same contract". With the delimiter defeated the twin answered rc 3 and
# this one answered rc 1 — laundered to ABSENT, missing the `probe_rc >= 2`
# hold arm, dropping the stamp for a window never observed. E5 pinned that
# belt for ONE resolver; this pins it for the other, and C8 is the paired
# control proving the belt did not just make everything refuse.
OLSTUB="$WORK/olstub"; mkdir -p "$OLSTUB"
cat > "$OLSTUB/tmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "list-windows" ]] || exit 0
printf 'zz-699-present_7\n'   # delimiter eaten, exactly as a C locale did
exit 0
STUB
chmod +x "$OLSTUB/tmux"
olstub() { env -u TMUX PATH="$OLSTUB:$EMPTYBIN" "$@"; }
assert_eq "C7 mangled row: rc 3 (could not look), NOT rc 1 'absent'" \
    "$(ol_probe olstub zz-699-present)" 3
# C8 — CONTROL. A WELL-SHAPED row for a window that is not in it must still be
# rc 1. Without this, C7 passes against a resolver that returns 3 for
# everything, which would wedge every over-limit stamp in a permanent hold.
OLSTUB2="$WORK/olstub2"; mkdir -p "$OLSTUB2"
cat > "$OLSTUB2/tmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "list-windows" ]] || exit 0
printf 'zz-some-other-window|7\n'
exit 0
STUB
chmod +x "$OLSTUB2/tmux"
olstub2() { env -u TMUX PATH="$OLSTUB2:$EMPTYBIN" "$@"; }
assert_eq "C8 CONTROL well-shaped row, name absent: still rc 1" \
    "$(ol_probe olstub2 zz-699-present)" 1

# =====================================================================
# Part D — the manifest, so the class cannot silently re-instantiate
# =====================================================================
#
# This repo has re-created this defect five times, and the reason is visible
# in the enumeration below: SEVEN independent name→id/index resolvers, written
# for different bugs, none aware of the others (the SEVENTH, _respawn_resolve_target_index, was found by this very manifest — the hand enumeration above it had missed it). `_target_window_present`
# had the correct three-state contract since the U1 respawn-storm and it never
# propagated. A manifest is the only thing that makes a FIFTH copy loud.
#
# THE BOUNDARY, stated on the axis the hazard varies on: this covers functions
# that map a window NAME to an id/index/presence answer. It does NOT cover the
# ~45 other `tmux list-windows 2>/dev/null` sites in monitor/ — most feed a
# grep whose failure arm is no-action, and converting them wholesale would
# churn review attention for no safety gain. The discriminator is not the
# swallowed stderr; it is whether a CONSUMER'S default arm acts.

echo
echo '=== D: resolver manifest — a fifth copy must not appear silently ==='

# name|file|contract. `3state` = distinguishes could-not-look.
# `2state-failclosed` = conflates, but EVERY consumer's default arm refuses,
# so the conflation cannot cause an action. That exemption is the finding,
# not an oversight: the defect was never the two-valued rc on its own.
# `resolve_window_key` (your-org/nexus-code#905) is `3state` on the axis this
# manifest measures — it distinguishes could-not-look (rc 3, tmux would not
# answer) from not-found (rc 1). It carries a FOURTH code, rc 4 AMBIGUOUS, for
# a key that is both a window NAME and a different window's INDEX; that is a
# refusal, so it fails closed in the same direction and does not weaken the
# contract.
# `not-a-resolver` = surfaced by the BEHAVIOURAL axis below (it touches
# `list-windows` and a window id/index) but maps no name to one — a lister, a
# consumer, or a prompt string. Declaring these is the price of the second
# axis, and it is worth paying: see D5.
#
# `_respawn_spawn_window` is the newest member and the one that is the
# OPPOSITE of a resolver, which is why it belongs here rather than under a
# contract (your-org/nexus-code#1327). It joined the behavioural axis by
# CEASING to key on a name: it now passes `-P -F '#{window_id}'` to
# `new-window` and reads the handle back, so it maps no name to anything — it
# MINTS an id for the window it just created and asks only "did I create one".
# The axis found it because it mentions `list-windows` (the pre-kill probe) and
# a `window_id` in the same body, which is the union working as designed: the
# manifest is loud about a function whose relationship to window identity
# changed, and the classification is what says which direction it changed in.
EXPECTED_RESOLVERS=$(cat <<'EOF'
_idle_list_worker_windows|monitor/watcher/_idle_probe.sh|not-a-resolver
_over_limit_evaluate_row|monitor/watcher/_over_limit.sh|not-a-resolver
_pd_resolve_window_index|monitor/watcher/_idle_probe.sh|3state
_over_limit_resolve_window_index|monitor/watcher/_over_limit.sh|3state
_paste_to_target_unlocked|monitor/watcher/main.sh|not-a-resolver
_recover_pin_orchestrator_window|monitor/bootstrap-recover.sh|not-a-resolver
_resolve_target_index|monitor/cc-auto-update-apply.sh|2state-failclosed
_resolve_window_index|monitor/skeptic-channel.sh|2state-failclosed
_respawn_render_prompt_fresh|monitor/watcher/_respawn_prompts.sh|not-a-resolver
_respawn_render_prompt_resume|monitor/watcher/_respawn_prompts.sh|not-a-resolver
_respawn_resolve_target_index|monitor/watcher/_respawn.sh|2state-failclosed
_respawn_spawn_window|monitor/watcher/_respawn.sh|not-a-resolver
_respawn_verify_target_absent|monitor/watcher/_respawn.sh|not-a-resolver
_target_window_present|monitor/watcher/_lib.sh|3state
_version_emit_section|monitor/watcher/_version_restart.sh|not-a-resolver
_version_window_id|monitor/watcher/_version_restart.sh|3state
cch_boot_worker|monitor/cc-harness/_lib.sh|not-a-resolver
list_bell_windows|monitor/watcher/main.sh|not-a-resolver
list_really_idle_workers|monitor/watcher/_idle_probe.sh|not-a-resolver
render_full_state_snapshot|monitor/watcher/_idle_probe.sh|not-a-resolver
render_pending_decisions|monitor/watcher/_idle_probe.sh|not-a-resolver
resolve_window_id|monitor/_tmux-window.sh|3state
resolve_window_index|monitor/_tmux-window.sh|3state
resolve_window_key|monitor/_tmux-window.sh|3state
_tmux_selection_rows|monitor/_tmux-window.sh|not-a-resolver
EOF
)
# `_tmux_selection_rows` (your-org/nexus-code#1528) enumerates the whole
# `session|window|name|active` table for the selection capture/restore across
# an orchestrator restart; it answers about no NAME. Its two arms are rows
# (rc 0) and could-not-look (rc 3, on a failed `list-windows -a` OR an
# unparseable row), and both consumers honour the second by doing NOTHING —
# the capture writes no file, the restore moves no window. The operation is
# cosmetic, so "do nothing" is the fail-closed arm there.
#
# DISCOVERY RUNS ON TWO AXES AND TAKES THEIR UNION, because neither is
# complete and `#700` shipped only the first (your-org/nexus-code#701 item B).
#
#   NAME  — `*resolve*window*`, `*resolve*target*`, `*window*present*`.
#           Catches anything following the existing conventions.
#   BEHAVIOUR — a function that calls `list-windows` AND mentions
#           `window_id`/`window_index`.
#
# The name axis alone MISSED `_version_window_id`, a two-valued resolver whose
# permissive consumer degraded an ID-targeted `kill-window` into a
# NAME-targeted one — the 2026-06-11 incident that code cites as its own
# reason to exist. `#700` stated the name-only limit honestly in this file and
# the limit bit on the very first independent probe.
#
# Neither axis subsumes the other, which is exactly why the union is the
# manifest. The behaviour axis misses `resolve_window_id`/`_index` (they call
# `list-windows` one layer down, through `_tmux_window_rows`) and
# `_target_window_present`; the name axis misses `_version_window_id`,
# `_recover_pin_orchestrator_window` and `_respawn_verify_target_absent`.
# `#700`'s comment predicted the behaviour axis would drown the manifest in
# benign sites; measured, it adds twelve, each classified in one word. Twelve
# declarations is a cheaper price than a resolver nobody can see.
REPO_ROOT=$(cd "$MON/.." && pwd)
_axis_name() {
    command grep -rEn \
        '^[[:space:]]*_?[a-z_]*(resolve[a-z_]*(window|target)|window[a-z_]*present)[a-z_]*\(\)' \
        --include='*.sh' monitor/ 2>/dev/null \
    | command grep -v '/test' \
    | sed -E 's|^([^:]+):[0-9]+:[[:space:]]*([A-Za-z_]+)\(\).*|\2\|\1|'
}
_axis_behaviour() {
    # The same enumeration `gp_population` declares (#803) — one function, so
    # the population this suite ADVERTISES cannot drift from the one it SCANS.
    # Paths are made relative to the repo root here because the manifest's
    # column 2 is repo-relative and `awk`'s FILENAME echoes what it was given.
    _resolver_scan_files | sed "s|^$REPO_ROOT/||" | tr '\n' '\0' \
    | xargs -0 awk '
        /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ {
            fn=$0; sub(/\(\).*/,"",fn); inside=1; body=""; next }
        inside && /^\}/ {
            if (body ~ /list-windows/ && body ~ /window_id|window_index/)
                print fn "|" FILENAME
            inside=0; next }
        inside { body = body "\n" $0 }'
}
FOUND=$(cd "$REPO_ROOT" && { _axis_name; _axis_behaviour; } | sort -u)
EXPECTED_PAIRS=$(cut -d'|' -f1,2 <<<"$EXPECTED_RESOLVERS" | sort -u)
if [[ "$FOUND" == "$EXPECTED_PAIRS" ]]; then
    printf '  PASS: %s\n' "D1 manifest: the union of both discovery axes is exactly the documented set"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "D1 manifest: window-resolver set CHANGED" >&2
    printf '    expected:\n%s\n    found:\n%s\n' \
        "$(sed 's/^/      /' <<<"$EXPECTED_PAIRS")" "$(sed 's/^/      /' <<<"$FOUND")" >&2
    printf '    A new name->window resolver must declare its contract. If it is\n' >&2
    printf '    three-state, say so here. If it conflates, prove EVERY consumer\n' >&2
    printf '    refuses on the failure arm before marking it 2state-failclosed\n' >&2
    printf '    — that exemption is about the CONSUMER, not the resolver.\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# D2 — the two exempt resolvers are exempt because their consumers refuse.
# Pin the refusal, not the comment: if someone makes either consumer
# permissive, the exemption silently becomes a live defect and this reddens.
# your-org/nexus-code#845 moved the refusal one level down, and this probe
# had to follow it or it would have pinned a LOCATION rather than the
# property. The rate-limit + pane-state precondition is now `_wake_gate`,
# shared by `nudge` (skeptic wakes its target) and by the reverse-direction
# `notify-delta` (target wakes its pinned skeptic) — one gate, two callers,
# because a second transcription of a guard is how two copies of a rule
# drift apart. So the unresolved arm now `return 1`s and each CALLER turns
# that into `exit 5`, and BOTH halves are checked: a three-line window
# around the resolver call alone would go green on a `_wake_gate` whose
# callers dropped the rc on the floor.
assert_contains "D2a skeptic-channel's shared wake gate refuses an unresolved index" \
    "$(sed -n '/_resolve_window_index "\$window"/,+3p' "$MON/skeptic-channel.sh")" "return 1"
_wg_total=$(command grep -c '^[[:space:]]*_wake_gate "' "$MON/skeptic-channel.sh")
_wg_refusing=$(command grep -c '^[[:space:]]*_wake_gate ".*|| exit 5' "$MON/skeptic-channel.sh")
assert_eq "D2b every _wake_gate call site turns that refusal into exit 5" \
    "$_wg_refusing" "$_wg_total"
# …and there must BE call sites. A rename that orphaned the gate would make
# `0 == 0` above and report success for a guard that checks nothing — the
# silent-zero class this repo keeps re-deriving.
assert_eq "D2c …and there is at least one such call site" \
    "$(( _wg_total >= 2 ? 1 : 0 ))" "1"
assert_contains "D3 cc-auto-update consumer still aborts on unresolved" \
    "$(sed -n '/target_idx=\$(_resolve_target_index/,+4p' "$MON/cc-auto-update-apply.sh")" "ABORT restart"
# D4 — `_respawn_resolve_target_index` was NOT in this suite's first hand
# enumeration; the manifest above found it on its first run, which is the
# entire argument for having one. Its consumer `_respawn_probe_state` returns
# empty, and both callers let an empty state fall through the `case` and keep
# polling — no action on "unknown". Pin that: a `*)` arm that acted would turn
# this exemption into the eighth instance of the class.
assert_not_contains "D4 respawn consumer takes no action on an unknown state" \
    "$(sed -n '/state=\$(_respawn_probe_state/,/esac/p' "$MON/watcher/_respawn.sh")" "*)"

# D5 — THE AXIS ITSELF IS THE FIX, not the one resolver it found. Pin that the
# behaviour axis actually sees `_version_window_id`, the resolver the name axis
# could not. If someone "simplifies" discovery back to a single grep, this
# reddens with the reason attached — otherwise the manifest quietly returns to
# being blind on the axis that has now missed a resolver twice.
assert_contains "D5 behaviour axis sees the resolver the name axis cannot" \
    "$(cd "$REPO_ROOT" && _axis_behaviour)" "_version_window_id|monitor/watcher/_version_restart.sh"
assert_not_contains "D5 CONTROL name axis genuinely cannot see it" \
    "$(cd "$REPO_ROOT" && _axis_name)" "_version_window_id"

# =====================================================================
# Part F — THE DELIMITER CLASS, closed on the axis it varies on
# =====================================================================
#
# `#699` fixed the delimiter of the resolvers it rewrote. `#701` item A found
# three more TAB-delimited production sites, one of them a safety guard that
# failed OPEN. Fixing those three closes three instances; this closes the
# CLASS, and it is deliberately NOT a grep for TAB — a TAB-shaped search is
# the same mistake as the name-shaped resolver search above.
#
# THE MEASURED RULE (tmux 2.6, this runner's tmux asserted below). tmux
# rewrites EVERY byte outside printable ASCII 0x20-0x7E in `-F` /
# `display-message -p` output to `_`. Not the TAB specifically: 0x01-0x1F,
# 0x7F and 0x80-0xFF all collapse to `_`, while every byte in 0x20-0x7E is
# returned unchanged. So the checkable rule is a RANGE, not a character:
#
#     a tmux format delimiter must be printable ASCII.
#
# AND IT NEEDS A SECOND CONDITION, which `#699`/`#700` did not state and
# which materially narrows the hazard (measured; F3 pins it). The rewrite
# fires only when the tmux client runs OUTSIDE a tmux session — `$TMUX`
# unset. With `$TMUX` set the TAB survives even under `LC_ALL=C`:
#
#     $TMUX set,   LC_ALL=C    -> TAB survives
#     $TMUX unset, LC_ALL=C    -> TAB rewritten to `_`
#     $TMUX set,   LC_ALL=utf8 -> TAB survives
#     $TMUX unset, LC_ALL=utf8 -> TAB survives
#
# Both conditions are required. That is why the class is latent rather than
# live in a running nexus — monitor/cc-harness/README.md states the invariant
# independently ("$TMUX is always set because every agent runs in a pane") —
# and it is also why THIS SUITE is more exposed than production: `#644`
# requires every fixture to run `env -u TMUX`, which is precisely the arming
# condition. The carriers that matter are cron, systemd, and any launcher
# that scrubs TMUX (monitor/watcher/launcher.sh has a supported `-z $TMUX`
# path) combined with a non-UTF-8 locale.

echo
echo '=== F: no tmux format string may use a non-printable delimiter ==='

# The checker, factored so F2/F5 can run it against planted violations.
#
# IT CHECKS THE PROPERTY, NOT A LIST OF SPELLINGS. The first cut of this lint
# grepped for `$'\t'`, `$'\n'`, `$'\r'` and a raw TAB — an enumeration of four
# known-bad spellings, shipped directly underneath a header announcing that the
# rule is a RANGE and therefore lintable. The insight and the implementation
# disagreed, and a reader trusts the header. `$'\v'`, `$'\f'`, `$'\x01'`,
# `$'\0101'` and a raw high byte would all have walked straight past it — which
# makes it not evidence, since it could not fail on anything nobody had already
# thought of. That is the very defect class this whole issue family is about,
# re-instantiated for the fourth time and the first time inside the fix that
# names it.
#
# The property: after shell parsing, every byte of a tmux format string must lie
# in 0x20-0x7E. Two steps, neither of which enumerates anything:
#
#   1. DECODE. `$'...'` is the only shell construct that turns an escape into a
#      non-printable byte at parse time, and `printf %b` is a general decoder
#      for it — \t \v \f \a \b \e \r \n \xHH \0NNN alike. Anything already in
#      the file as a raw byte needs no decoding.
#   2. RANGE-TEST. `[^ -~]` under LC_ALL=C is exactly "outside 0x20-0x7E" in
#      byte semantics. Both steps are asserted against the live tmux in F3.
#
# `#{...}` tokens need no stripping: they are printable ASCII themselves.
delim_violations() {
    local root="$1"
    # `-a` ON EVERY PRINTING STAGE IS LOAD-BEARING, and F5's raw-byte case is
    # what found it. GNU grep classifies input containing a raw non-ASCII byte
    # as BINARY and then prints "Binary file X matches" INSTEAD of the matching
    # line. So the one violation shape needing no decoding at all was dropped
    # silently, and the pure-ASCII banner printed in its place sailed through
    # the range test as clean — a checker blind to exactly the input it exists
    # to catch, failing by reporting nothing rather than by erroring.
    #
    # It bites at BOTH printing layers: the recursive search over files, and
    # each intermediate filter reading the pipe ("Binary file (standard input)
    # matches"). Measured, both.
    #
    # THE LINE THIS DRAWS IS `-q` VS PRINTING, and it is worth knowing: binary
    # detection replaces grep's OUTPUT, it does not change its EXIT STATUS. So
    # `grep -q` is unaffected, and the assert_* helpers above — which are all
    # `-q` — need no `-a`. An earlier cut of this fix "hardened" them anyway on
    # the assumption that grep refuses to match binary input at all. It does
    # not; the mutant that should have reddened for that change refused to, and
    # that refusal is what exposed the false premise.
    command grep -arn '#{' --include='*.sh' "$root" 2>/dev/null \
        | command grep -av '/test' \
        | command grep -avE ':[0-9]+:[[:space:]]*#' \
    | while IFS= read -r _line; do
        local _dec="$_line" _seg _body _out
        # Decode every $'...' segment in place. The `; printf X` guard is not a
        # nicety: command substitution strips trailing newlines, so a $'\n'
        # delimiter would decode to the empty string and vanish — the checker
        # would go blind on one of the very bytes it exists to catch.
        while [[ "$_dec" =~ \$\'([^\']*)\' ]]; do
            _seg="${BASH_REMATCH[0]}"; _body="${BASH_REMATCH[1]}"
            _out=$(printf '%b' "$_body"; printf X); _out="${_out%X}"
            _dec="${_dec//"$_seg"/"$_out"}"
        done
        if LC_ALL=C command grep -q '[^ -~]' <<<"$_dec"; then
            printf '%s\n' "$_line"
        fi
    done
}

_viol=$(delim_violations "$REPO_ROOT/monitor")
if [[ -z "$_viol" ]]; then
    printf '  PASS: %s\n' "F1 every tmux format delimiter in monitor/ is printable ASCII"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "F1 a tmux format string uses a NON-PRINTABLE delimiter" >&2
    printf '%s\n' "$_viol" | sed 's/^/      /' >&2
    printf '    In a non-UTF-8 locale with $TMUX unset, tmux rewrites this byte to\n' >&2
    printf '    `_`, the row never splits, and the consumer gets one mangled field\n' >&2
    printf "    instead of two. Use '|' — printable, so no locale rewrites it, and\n" >&2
    printf '    validate_window_name forbids it inside a minted window name.\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# F2 — NEGATIVE CONTROL. An all-clear from a checker that cannot detect
# anything is the exact failure mode this repo keeps re-learning, so plant
# each forbidden shape and require the checker to catch it.
PLANT="$WORK/plant/monitor"; mkdir -p "$PLANT"
printf 'x=$(tmux list-windows -F "#{window_id}"$%s"#{window_name}")\n' "'\\t'" > "$PLANT/a.sh"
printf 'y=$(tmux display-message -p "#{window_id}\t#{window_name}")\n' > "$PLANT/b.sh"
_planted=$(delim_violations "$PLANT")
assert_contains "F2 CONTROL checker catches a planted \$'\\t' delimiter" "$_planted" "a.sh"
assert_contains "F2 CONTROL checker catches a planted literal-TAB delimiter" "$_planted" "b.sh"

# F5 — THE ASSERTION THAT MAKES THIS A PROPERTY CHECK AND NOT A LIST.
#
# F2 only plants the two spellings the original enumeration already knew about,
# so it passed against a lint that could not fail on anything else. These are
# spellings NOBODY ENUMERATED: a vertical tab, a form feed, a hex escape, an
# octal escape, and a raw high byte. A lint that cannot fail on an unlisted
# spelling is not evidence — so each of these must be caught, and each one is
# a byte the range rule forbids for exactly the same reason the TAB is.
PLANT2="$WORK/plant2/monitor"; mkdir -p "$PLANT2"
printf 'v=$(tmux list-windows -F "#{window_id}"$%s"#{window_name}")\n' "'\\v'"    > "$PLANT2/vt.sh"
printf 'f=$(tmux list-windows -F "#{window_id}"$%s"#{window_name}")\n' "'\\f'"    > "$PLANT2/ff.sh"
printf 'h=$(tmux list-windows -F "#{window_id}"$%s"#{window_name}")\n' "'\\x01'"  > "$PLANT2/hex.sh"
printf 'o=$(tmux list-windows -F "#{window_id}"$%s"#{window_name}")\n' "'\\0101'" > "$PLANT2/oct.sh"
# A RAW 0x80 straight in the source — no escape to decode at all.
printf 'r=$(tmux list-windows -F "#{window_id}\x80#{window_name}")\n'             > "$PLANT2/raw.sh"
_planted2=$(delim_violations "$PLANT2")
assert_contains     "F5 catches an UNLISTED spelling: \$'\\v'"        "$_planted2" "vt.sh"
assert_contains     "F5 catches an UNLISTED spelling: \$'\\f'"        "$_planted2" "ff.sh"
assert_contains     "F5 catches an UNLISTED spelling: \$'\\x01'"      "$_planted2" "hex.sh"
assert_contains     "F5 catches a raw non-ASCII byte in the source"   "$_planted2" "raw.sh"
# The octal escape decodes to 'A' (0x41) — PRINTABLE, so it is legal. This is
# the control that keeps F5 from passing against a lint that flags every
# `$'...'` it sees: the rule is the resulting BYTE, not the presence of an
# escape.
assert_not_contains "F5 CONTROL \$'\\0101' decodes to 'A' — legal, not flagged" \
    "$_planted2" "oct.sh"

# F3 — THE RULE ITSELF, measured against THIS runner's tmux rather than
# inherited from the issue. Asserting the range on a live server is what makes
# the '|' choice evidence instead of folklore, and what would catch a future
# tmux that changed the rewrite. Uses the private server; `$TMUX` is unset by
# `srv`, which is the arming condition described above.
_tab=$(printf '\t')
_c_tab=$(c_srv tmux list-windows -F "A${_tab}B" 2>/dev/null | head -1)
_c_pipe=$(c_srv tmux list-windows -F 'A|B' 2>/dev/null | head -1)
assert_eq "F3 non-UTF-8 + \$TMUX unset: a TAB delimiter IS rewritten" "$_c_tab" "A_B"
assert_eq "F3 CONTROL: a '|' delimiter survives the same conditions" "$_c_pipe" "A|B"
# F4 — the second condition. With $TMUX SET the same locale does NOT rewrite.
# This is the claim that keeps the class honest: it is why the hazard is
# latent in a running nexus, and stating it is the difference between a
# mechanism and an incident. $TMUX is not a flag — it IS the socket path, so
# it has to be the fixture's real socket for tmux to connect at all.
_sock=$(find "$PRIV" -type s 2>/dev/null | head -1)
if [[ -S "$_sock" ]]; then
    _inside=$(env LC_ALL=C TMUX_TMPDIR="$PRIV" TMUX="$_sock,1,0" \
                  tmux list-windows -F "A${_tab}B" 2>/dev/null | head -1)
    assert_eq "F4 non-UTF-8 but \$TMUX SET: the TAB survives (hazard needs BOTH)" \
        "$_inside" "A${_tab}B"
else
    printf '  FAIL: %s\n' "F4 could not locate the fixture socket — the \$TMUX condition went UNTESTED" >&2
    FAIL=$(( FAIL + 1 ))
fi

# =====================================================================
# Part G — the EIGHTH resolver, and the consumer that undid its purpose
# =====================================================================
#
# `_version_window_id` (your-org/nexus-code#701 item B) resolves the cockpit
# window's immutable @id so the surfaced restart recipe cannot be mis-aimed.
# It exists BECAUSE of the 2026-06-11 incident: a name-targeted kill executed
# by the orchestrator destroyed the orchestrator's own window. It was
# two-valued, and — worse — its consumer rendered
# `${window_id:-${window:-services}}`, so an empty id silently degraded the
# recipe back to a NAME-targeted `kill-window`. The guard turned into the
# thing it guards against, most readily in the degraded conditions where a
# mis-aim is likeliest.

echo
echo '=== G: _version_window_id three-state + no name-targeted fallback ==='

vw_probe() {  # vw_probe <env-fn> <name> — rc of the resolver in isolation
    local envfn="$1" name="$2"
    "$envfn" bash -c '
        set -uo pipefail
        . "$1" 2>/dev/null
        _version_window_id "$2" >/dev/null
    ' _ "$MON/watcher/_version_restart.sh" "$name"
    printf '%s' "$?"
}
assert_eq "G1 no-tmux: rc 3 (could not look), was rc 1 'absent'"   "$(vw_probe notmux "$PRESENT_WIN")" 3
assert_eq "G2 no-server: rc 3 (could not look), was rc 1 'absent'" "$(vw_probe nosrv  "$PRESENT_WIN")" 3
assert_eq "G3 CONTROL absent: still rc 1"                          "$(vw_probe srv    zz-699-definitely-absent)" 1
assert_eq "G4 CONTROL present: still rc 0"                         "$(vw_probe srv    "$PRESENT_WIN")" 0

# G5/G6 — THE CONSUMER, behaviourally. Render the advisory from a drift record
# with an EMPTY window_id and assert what comes out. G5 is the rule; G6 is the
# control proving the ID-targeted path is untouched when the id IS known.
vw_emit() {  # vw_emit <window_id> — the rendered cockpit advisory
    local wid="$1" d="$WORK/vst.$RANDOM$$"
    mkdir -p "$d"
    { printf 'component=cockpit\n'; printf 'new=deadbeefcafe\n'; printf 'old=0123456789ab\n'
      printf 'window=services\n'; printf 'window_id=%s\n' "$wid"; printf 'detected=now\n'
    } > "$d/drift-cockpit"
    srv bash -c '
        set -uo pipefail
        . "$1" 2>/dev/null
        _version_emit_section "$2" /nx 2>/dev/null
    ' _ "$MON/watcher/_version_restart.sh" "$d"
}
_emit_empty=$(vw_emit "")
assert_not_contains "G5 empty id: NO bare name-targeted kill-window is rendered" \
    "$_emit_empty" "kill-window -t services"
assert_contains     "G5 empty id: the recipe resolves the id at paste time instead" \
    "$_emit_empty" 'wid=$(tmux list-windows'
_emit_known=$(vw_emit "@7")
assert_contains     "G6 CONTROL known id: still renders the ID-targeted kill" \
    "$_emit_known" "kill-window -t @7"

# =====================================================================
# Part H — the guard that failed OPEN
# =====================================================================
#
# `_nexus_self_pane_window` (your-org/nexus-code#701 item A) told svc.sh and
# watcher/main.sh which window hosts them, so each could refuse to squat the
# orchestrator's window. Its row was TAB-delimited: mangled, BOTH `%%$'\t'*`
# and `#*$'\t'` yielded the whole string, the name never matched, and the
# guard silently did not fire.
#
# The fix is not a safer delimiter but NO PARSE AT ALL — each field is queried
# separately. That matters here specifically: this function's failure arm is
# `return 1` and both consumers read that as "not applicable, carry on", so a
# refusing belt would ALSO fail open, while a fail-CLOSED arm could stop the
# cockpit and the watcher from launching. The parse had to become infallible
# rather than merely loud.

echo
echo '=== H: _nexus_self_pane_window survives a delimiter-hostile tmux ==='

# A stub tmux that answers each single-field query cleanly but would mangle
# any MULTI-field format — i.e. the exact capability profile of a real tmux
# under the arming conditions. pane_pid answers with the caller's own pid so
# the ancestry check passes (_nexus_pid_is_ancestor returns 0 for pid==anc).
HSTUB="$WORK/hstub"; mkdir -p "$HSTUB"
cat > "$HSTUB/tmux" <<'STUB'
#!/usr/bin/env bash
# args: display-message -p -t <pane> <format>
fmt="${!#}"
case "$fmt" in
    '#{pane_pid}')   printf '%s\n' "$ZZ_PANE_PID" ;;
    '#{window_id}')  printf '@0\n' ;;
    '#{window_name}') printf 'zz-701-guardwin\n' ;;
    *) printf '%s\n' "${fmt//\#\{*\}/}" | tr -d '\n'
       printf '@0_zz-701-guardwin\n' ;;   # any multi-field format: mangled
esac
exit 0
STUB
chmod +x "$HSTUB/tmux"
h_out=$(env -u TMUX PATH="$HSTUB:$EMPTYBIN" TMUX_PANE='%9' bash -c '
    set -uo pipefail
    export ZZ_PANE_PID=$$
    . "$1" 2>/dev/null
    info=$(_nexus_self_pane_window) || { printf "RC-NONZERO"; exit 0; }
    id="${info%%|*}"; nm="${info#*|}"
    printf "%s\t%s" "$id" "$nm"
' _ "$MON/watcher/_lib.sh")
assert_eq "H1 window id is parsed cleanly"   "${h_out%%$'\t'*}" "@0"
assert_eq "H2 window NAME is parsed cleanly" "${h_out##*$'\t'}" "zz-701-guardwin"
# H3 — the rule, stated as the consumers state it. Before the fix BOTH fields
# were the mangled whole string, so this comparison was false and the guard
# did not fire. Assert the decision, not the bytes.
if [[ "${h_out##*$'\t'}" == "zz-701-guardwin" ]]; then
    printf '  PASS: %s\n' "H3 the squatting guard's name test FIRES (was: silently open)"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — guard would not fire; got %q\n' "H3 squatting guard" "$h_out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# =====================================================================
# Part I — a `session:window` key is judged against THAT session
#          (your-org/nexus-code#944)
# =====================================================================
#
# THE PROPERTY, stated so it does not depend on which session tmux considers
# current: `resolve_window_key "S:K"` answers from session S's window list.
#
# That phrasing is deliberate and is what makes I3 a real discriminator. A
# suite that pinned "the answer when session X is current" would be pinning an
# ambient tmux fact this fixture does not control -- there is no attached
# client here, so "current" is whichever session tmux last touched, and merely
# CREATING the second session moves it. Instead the two sessions get DISJOINT
# window names and BOTH keys are resolved: session-blind rows answer both keys
# from the same session, so whichever one is current, at least one of I1/I2
# must fail and I3 must fail. The property is checkable without controlling
# the ambient fact.
#
# WHY IT MATTERS BEYOND A WRONG PASTE. `paste-followup.sh` consumes this
# stdout, so the measured consequence was a paste into a window the key did not
# name. But the same resolver backs `pane-state.sh`'s ambiguity refusal, and
# `pane-state.sh`'s answer can authorise a kill -- `absent` is in
# `_bookkeeping.sh`'s kill allowlist. I4 is the arm that matters there: a
# session tmux cannot find must yield rc 3 COULD NOT LOOK, never a confident
# answer about some other session's window.

echo
echo '=== I: a session:window key is judged against the NAMED session ==='

# I6 FIRST, while s699 is still the only session. A key with NO session part
# means "the session I am in", and that has to stay true -- the fix must scope
# only what the caller scoped. Ordered before the second session exists
# precisely because creating one changes which session is current, so asserting
# it afterwards would be asserting an ambient fact rather than the contract.
r=$(run3 srv bash "$HELPER" key "$PRESENT_WIN")
assert_eq "I6 CONTROL bare name (single session): rc 0" "$(f_rc "$r")" 0
assert_eq "I6 CONTROL bare name (single session): resolves to itself" "$(f_out "$r")" "$PRESENT_WIN"

S944=zz-944-other
srv tmux new-session -d -s "$S944" -n zz-944-alpha 2>/dev/null \
    || { echo "SETUP FAILED: could not create the second fixture session" >&2; exit 1; }
srv tmux set-window-option -t "$S944:" automatic-rename off >/dev/null 2>&1 || true
srv tmux new-window -t "$S944:" -d -n zz-944-bravo >/dev/null 2>&1 || true

# Derive the indices from tmux rather than assuming base-index=0. This fixture
# runs where base-index is 1, and the first cut of this block hard-coded a
# collision window named `1` that duly collided with the index it was NOT meant
# to -- swallowing the clean arm instead of the collision arm. A fixture that
# hard-codes an index it did not measure is one `base-index` setting away from
# asserting something else.
_widx() {
    srv tmux list-windows -t "$1:" -F '#{window_index}|#{window_name}' 2>/dev/null \
        | awk -F'|' -v n="$2" '$2==n{print $1; exit}'
}
I699=$(_widx s699 "$PRESENT_WIN")
I944A=$(_widx "$S944" zz-944-alpha)
I944B=$(_widx "$S944" zz-944-bravo)
[[ -n "$I699" && -n "$I944A" && -n "$I944B" && "$I944A" != "$I944B" ]] || {
    echo "SETUP FAILED: fixture window indices unusable (I699=$I699 I944A=$I944A I944B=$I944B) — every Part I assertion would be vacuous" >&2
    exit 1
}

# The collision window is NAMED AFTER bravo's measured index, so the plant is
# self-consistent at any base-index and cannot shadow alpha's key.
srv tmux new-window -t "$S944:" -d -n "$I944B" >/dev/null 2>&1 || true
_icol=$(_widx "$S944" "$I944B")
[[ -n "$_icol" && "$_icol" != "$I944B" ]] || {
    echo "SETUP FAILED: collision plant did not take (window named '$I944B' sits at index '$_icol') — I5 would assert nothing" >&2
    exit 1
}

r=$(run3 srv bash "$HELPER" key "s699:$I699")
assert_eq "I1 s699:<idx> resolves inside s699"  "$(f_out "$r")" "$PRESENT_WIN"
r=$(run3 srv bash "$HELPER" key "$S944:$I944A")
assert_eq "I2 <other>:<idx> resolves inside the OTHER session" "$(f_out "$r")" "zz-944-alpha"

# I3 — the discriminator. Session-blind rows make these two keys answer with
# the same window; they name different sessions, so they must not.
_i3a=$(f_out "$(run3 srv bash "$HELPER" key "s699:$I699")")
_i3b=$(f_out "$(run3 srv bash "$HELPER" key "$S944:$I944A")")
if [[ -n "$_i3a" && -n "$_i3b" && "$_i3a" != "$_i3b" ]]; then
    printf '  PASS: %s\n' "I3 two keys naming DIFFERENT sessions answer with different windows"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — got %q and %q\n' \
        "I3 two keys naming DIFFERENT sessions answer with different windows" "$_i3a" "$_i3b" >&2
    FAIL=$(( FAIL + 1 ))
fi

# I4 — the SAFETY arm. A session tmux cannot find is COULD NOT LOOK, never a
# confident answer, and never rc 1 "absent" (which downstream reads as a dead
# window and `_bookkeeping.sh` treats as kill-authorised).
r=$(run3 srv bash "$HELPER" key "zz-944-nosuchsession:$I699")
assert_eq       "I4 unknown session: rc 3 (could not look), NOT 0 and NOT 1" "$(f_rc "$r")" 3
assert_contains "I4 unknown session: says UNKNOWN, not absent" "$(f_err "$r")" "UNKNOWN, not absent"
assert_eq       "I4 unknown session: prints NO window name" "$(f_out "$r")" ""

# I5 — the NAMED session's collision is refused. The un-scoped read could not
# see a collision living in a session other than the current one, so the
# refusal silently did not fire: the ANSWER was wrong and the SAFEGUARD was
# absent, from the same one-line cause.
r=$(run3 srv bash "$HELPER" key "$S944:$I944B")
assert_eq       "I5 collision in the NAMED session: rc 4 (ambiguous)" "$(f_rc "$r")" 4
assert_contains "I5 collision in the NAMED session: names both candidates" "$(f_err "$r")" "AMBIGUOUS key"

# I7 — THE SECOND HALF OF #944, and without it the first half emits a FALSE
#      DIAGNOSTIC. `resolve_window_key` now correctly resolves `sess:idx` to a
#      NAME in that session — but a caller re-resolving that NAME to an @id got
#      a session-BLIND lookup, rc 1, and `paste-followup.sh` rendered that as
#      "it closed between the check above and now (race with a close)". The
#      window had not closed. A wrong diagnosis is worse than none: it sends
#      the reader to a mechanism that did not occur.
# BOTH sessions are probed explicitly, and neither arm depends on which session
# tmux considers current — there is no attached client here, so "current" is
# ambient and the first cut of this arm asserted it by accident.
_i7b=$(run3 srv bash -c "source '$HELPER'; resolve_window_id '$PRESENT_WIN' s699; printf 'rc=%s' \"\$?\"")
assert_matches "I7 a name in s699 resolves when s699 is named" "$(f_out "$_i7b")" '@[0-9]+.*rc=0'
_i7=$(run3 srv bash -c "source '$HELPER'; resolve_window_id zz-944-alpha '$S944'; printf 'rc=%s' \"\$?\"")
assert_matches "I7 …and WITH the session it resolves to an @id at rc 0" "$(f_out "$_i7")" '@[0-9]+.*rc=0'

# I8 — the same for resolve_window_index, asserted independently rather than
#      assumed: it is a separate function body, and the defect class here is
#      one copy being fixed while its twin is not.
_i8=$(run3 srv bash -c "source '$HELPER'; resolve_window_index zz-944-bravo '$S944'; printf 'rc=%s' \"\$?\"")
assert_matches "I8 index resolves inside the named session at rc 0" "$(f_out "$_i8")" '^[0-9]+.*rc=0'

# I9 — the session a caller must carry is PUBLISHED by resolve_window_key, or
#      the caller cannot pass it on. This is the whole linkage between the two
#      halves, so it is asserted rather than assumed.
_i9=$(run3 srv bash -c "source '$HELPER'; resolve_window_key '$S944:$I944A' >/dev/null; printf '%s' \"\${RESOLVED_WINDOW_SESSION:-UNSET}\"")
assert_eq "I9 resolve_window_key publishes the session it parsed" "$(f_out "$_i9")" "$S944"
_i9b=$(run3 srv bash -c "source '$HELPER'; resolve_window_key '$PRESENT_WIN' >/dev/null; printf '[%s]' \"\${RESOLVED_WINDOW_SESSION-UNSET}\"")
assert_eq "I9 …and publishes EMPTY for a key with no session part" "$(f_out "$_i9b")" "[]"

# =====================================================================
# Part J — a bare key's AMBIGUITY check spans SESSIONS
#          (your-org/nexus-code#1318)
# =====================================================================
#
# ADJACENT TO `#1281`, NOT A REFUTATION OF IT, and that sentence is load-bearing
# because the next reader will otherwise take this band as "the #1281 fix does
# not work", which is measurably false. `#1281` closed a fail-open reached when
# the resolver library is UNAVAILABLE. This is a fail-open reached while it is
# present and working, found by varying an axis nobody had varied: the NUMBER
# of tmux sessions.
#
# THE DEFECT. `resolve_window_key`'s collision check read ONE session's rows —
# the current one, for a bare key, because no caller supplies a session and
# none can see which session tmux considers current. A name/index collision
# that SPANS sessions was therefore invisible: the resolver found no collision
# and returned a confident answer about a window the key names in no sense.
# Downstream, `pane-state.sh` classified THAT window, and the classification
# measured on a private socket was `absent` — the one KILL-AUTHORISING state —
# at rc 0 with an empty stderr. Which window you got depended on session FOCUS,
# so the wrong answer was not even reproducible from the arguments.
#
# THE ARRANGEMENT. Part I left two sessions with DISJOINT window names. A third
# session gets a window NAMED after an index that exists in s699, so the two
# halves of the collision sit in different sessions and NEITHER session alone
# shows one. J4 is the one-variable control: kill that third session and the
# same key must resolve again.

echo
echo '=== J: a bare key collides across SESSIONS, and only the REFUSAL widens ==='

S1318=zz-1318-name
srv tmux new-session -d -s "$S1318" -n zz-1318-filler 2>/dev/null \
    || { echo "SETUP FAILED: could not create the third fixture session" >&2; exit 1; }
srv tmux set-window-option -t "$S1318:" automatic-rename off >/dev/null 2>&1 || true
# The collision's NAME side: a window in the THIRD session named after
# PRESENT_WIN's INDEX in s699.
srv tmux new-window -t "$S1318:" -d -n "$I699" >/dev/null 2>&1 || true

# PRECONDITIONS, asserted rather than assumed — each one, if false, makes every
# assertion below pass or fail for a reason that is not the property. Part I
# learned this the hard way with a hard-coded index at the wrong base-index.
_jname_idx=$(_widx "$S1318" "$I699")
[[ -n "$_jname_idx" ]] || {
    echo "SETUP FAILED: the window named '$I699' was not created in $S1318 — J1 would assert nothing" >&2; exit 1; }
# Nothing in s699 may be NAMED $I699, or the collision is single-session and
# the PRE-EXISTING check would catch it — J1 would then prove nothing new.
# HERESTRING, NOT A PIPE. `grep -q` exits on its first match and SIGPIPEs the
# producer, so under `pipefail` the pipeline reports 141 — a FALSE FAILURE on
# the very input that matched. `test-sigpipe-assertion-lint.sh` catches this
# repo-wide and caught both of this band's first-cut instances.
_j_s699_names=$(srv tmux list-windows -t 's699:' -F '#{window_name}' 2>/dev/null)
if grep -qxF "$I699" <<<"$_j_s699_names"; then
    echo "SETUP FAILED: s699 already holds a window NAMED '$I699' — the collision would not span sessions" >&2; exit 1
fi

# J1 — THE DEFECT. Bare key, the collision spanning two sessions: REFUSE.
r=$(run3 srv bash "$HELPER" key "$I699")
assert_eq       "J1 a bare key colliding ACROSS sessions is rc 4 AMBIGUOUS" "$(f_rc "$r")" 4
assert_eq       "J1 …and prints NO window name"                            "$(f_out "$r")" ""
assert_contains "J1 …and the diagnostic names both sessions"               "$(f_err "$r")" "$S1318:"
assert_contains "J1 …and offers the session:window remedy"                 "$(f_err "$r")" "session:window"

# J3 — THE SCOPING CONTROL, run while the collision is still standing. The
# sweep is for BARE keys only: an explicit `session:window` key over the SAME
# colliding number must still be judged against the session it names, at rc 0.
# `#944`'s I1-I5 hold by construction here, and this asserts that rather than
# trusting the construction.
r=$(run3 srv bash "$HELPER" key "s699:$I699")
assert_eq "J3 an explicit session:window key over the same number still resolves" "$(f_rc "$r")" 0
assert_eq "J3 …inside the session it NAMES"  "$(f_out "$r")" "$PRESENT_WIN"

# J4 — THE ONE-VARIABLE POTENCY CONTROL. Remove the third session and nothing
# else; the same key must stop being refused. Without this, J1 is satisfied by
# any arrangement that refuses for any reason at all — which is precisely how
# the fixture `#1282` had to replace passed for months.
#
# IT ASSERTS "NOT REFUSED", NOT "RESOLVES TO PRESENT_WIN". Which window a bare
# key answers with depends on the CURRENT session, and killing a session moves
# which session is current — so pinning the identity here would pin an ambient
# fact rather than the property. A cut of this did exactly that and got
# `zz-944-alpha`, a correct answer to a question the assertion had not asked.
srv tmux kill-session -t "$S1318" >/dev/null 2>&1 || true
r=$(run3 srv bash "$HELPER" key "$I699")
assert_eq "J4 POTENCY: with the third session gone, the same key is NOT refused" "$(f_rc "$r")" 0
if [[ -n "$(f_out "$r")" ]]; then
    printf '  PASS: %s\n' "J4 POTENCY: …and names a window again"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "J4 POTENCY: …and names a window again — got empty" >&2
    FAIL=$(( FAIL + 1 ))
fi

# J2 — THE NON-WIDENING CONTROL, and the one that matters most. This suite's
# own rule is that a change which only widens refusal is NOT a fix: it breaks
# ordinary retirement, the far more common path. A bare numeric key with no
# name-side anywhere on the server must still resolve, at rc 0, exactly as
# before.
#
# IT RUNS LAST, IN A SESSION BUILT FOR IT, AND THAT ORDERING IS THE FIX FOR TWO
# WRONG CUTS — both of them Part I's ambient-fact warning arriving in a new
# band:
#
#   1. picking `zz-1318-filler`'s index chose a number that WAS somebody's
#      name — J1's own plant, since `$I699` is `1` on this host and the filler
#      sat at index 1 too. It would have measured the collision it exists to
#      exclude.
#   2. searching `list-windows -a` for a free index chose one that may live in
#      a session that is not current — and the ANSWER path for a bare key
#      reads the current session only, deliberately (`#944` I6). rc 1 "no such
#      window" is then CORRECT and the assertion simply wrong.
#   3. searching the CURRENT session found nothing free, because by then every
#      index in it was also some window's name. A search that can come up empty
#      is a fixture that skips, and a skipping fixture is how `#1282` happened.
#
# So the arrangement is CONSTRUCTED rather than found: a fresh session (which
# becomes current by the act of creating it), widened with non-numeric window
# names until one of its indices is nobody's name server-wide. Bounded, and a
# loud abort if the bound is reached.
srv tmux new-session -d -s zz-1318-clean -n zz-1318-solo 2>/dev/null \
    || { echo "SETUP FAILED: could not create the J2 fixture session" >&2; exit 1; }
srv tmux set-window-option -t 'zz-1318-clean:' automatic-rename off >/dev/null 2>&1 || true
_jfree=""
for _grow in 1 2 3 4 5 6; do
    _jnames=$(srv tmux list-windows -a -F '#{window_name}' 2>/dev/null)
    _jcur=$(srv tmux list-windows -t 'zz-1318-clean:' -F '#{window_index}' 2>/dev/null)
    for _cand in $(printf '%s\n' "$_jcur" | sort -u); do
        grep -qxF "$_cand" <<<"$_jnames" && continue
        _jfree="$_cand"; break
    done
    [[ -n "$_jfree" ]] && break
    srv tmux new-window -t 'zz-1318-clean:' -d -n "zz-1318-pad$_grow" >/dev/null 2>&1 || true
done
[[ -n "$_jfree" ]] || {
    echo "SETUP FAILED: could not construct an index in the current session that is nobody's NAME — J2 would measure a collision, not a clean key" >&2; exit 1; }
r=$(run3 srv bash "$HELPER" key "$_jfree")
assert_eq "J2 CONTROL a bare index with NO name-side anywhere still resolves at rc 0" "$(f_rc "$r")" 0
if [[ -n "$(f_out "$r")" ]]; then
    printf '  PASS: %s\n' "J2 CONTROL …and names a window, so the sweep did not widen past its remit"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "J2 CONTROL …and names a window — got empty, so the sweep widened past its remit" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- summary ------------------------------------------------------------
#
# Expected-count guard: an assert_* that never runs reports 0 failures and
# reads as a pass — the defect class this whole suite is about.
EXPECTED=103  # 78 + Part I x15 (#944) + Part J x10 (#1318: the collision check spans sessions)
echo
echo "=== summary: $PASS passed, $FAIL failed ($(( PASS + FAIL )) assertions; expected $EXPECTED) ==="
if (( PASS + FAIL != EXPECTED )); then
    echo "ASSERTION COUNT MISMATCH — $(( PASS + FAIL )) ran, $EXPECTED expected." >&2
    exit 1
fi
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
