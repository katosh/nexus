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
    if grep -qF -- "$needle" <<<"$hay"; then
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
    cp "$NG_REAL" "$FAKE/monitor/ng"
    cp "$MON/_bookkeeping.sh" "$FAKE/monitor/_bookkeeping.sh"
    cp "$HELPER" "$FAKE/monitor/_tmux-window.sh"
    chmod +x "$FAKE/monitor/ng"
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
# `not-a-resolver` = surfaced by the BEHAVIOURAL axis below (it touches
# `list-windows` and a window id/index) but maps no name to one — a lister, a
# consumer, or a prompt string. Declaring these is the price of the second
# axis, and it is worth paying: see D5.
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
EOF
)
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
assert_contains "D2 skeptic-channel consumer still fails safe on unresolved" \
    "$(sed -n '/_resolve_window_index "\$window"/,+3p' "$MON/skeptic-channel.sh")" "exit 5"
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
        if printf '%s' "$_dec" | LC_ALL=C command grep -q '[^ -~]'; then
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

# ---- summary ------------------------------------------------------------
#
# Expected-count guard: an assert_* that never runs reports 0 failures and
# reads as a pass — the defect class this whole suite is about.
EXPECTED=72
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
