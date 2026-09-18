#!/usr/bin/env bash
# Fixture-driven tests for monitor/pane-state.sh.
#
# Each fixture under monitor/watcher/fixtures/*.ansi is a real or
# synthesized tmux capture-pane -e -p output. The expected state for each
# fixture comes from monitor/watcher/pane-state-fixtures.manifest — DATA,
# independent of the fixture's filename (your-org/nexus-code#1176). It used to
# be derived from a filename PREFIX, which meant the suite could not disagree
# with the classifier about anything nameable and could not express the one
# case this corpus is most valuable for: "looks like X, must classify as Y".
#
# Run: bash monitor/watcher/test-pane-state.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/pane-state.sh"
FIX_DIR="$_test_dir/fixtures"

PASS=0
FAIL=0

# assert_state <fixture> <want> [<env-assignment>...] [--] [<extra-arg>...]
#
# `env` and `args` come from the manifest, so a capture can be read under more
# than one scenario (a process tree, a ledger) without needing a second copy of
# the bytes. Both default to empty, which is the bare reading.
assert_state() {
    local fixture="$1" want="$2"; shift 2
    local -a envv=() extra=()
    while (( $# > 0 )); do
        [[ "$1" == "--" ]] && { shift; break; }
        envv+=("$1"); shift
    done
    extra=("$@")
    local label
    label=$(basename "$fixture")
    (( ${#envv[@]} || ${#extra[@]} )) && label="$label [${envv[*]} ${extra[*]}]"
    local out got
    out=$(env "${envv[@]}" "$HELPER" --fixture "$fixture" \
              --window 9 --name testwin --active 0 "${extra[@]}" 2>&1) || {
        printf '  FAIL: %s — helper exited nonzero: %s\n' "$label" "$out" >&2
        FAIL=$(( FAIL + 1 ))
        return
    }
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %-50s state=%s\n' "$label" "$got"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %-50s got=%s want=%s (full: %s)\n' \
            "$label" "$got" "$want" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

MANIFEST="$_test_dir/pane-state-fixtures.manifest"

# The manifest's data rows, TAB-separated: fixture, expect, env, args, why.
# Comments and blank lines dropped here so every consumer sees the same rows.
_ps_manifest_rows() {
    grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$'
}

[[ -x "$HELPER" ]] || { echo "helper not executable: $HELPER" >&2; exit 1; }
[[ -d "$FIX_DIR" ]] || { echo "fixtures dir missing: $FIX_DIR" >&2; exit 1; }

# The fixture corpus, as ONE function, because two things need it: the
# classification loop below and the `--population` declaration. A second
# implementation of "which fixtures exist" is exactly the drift the protocol's
# one rule exists to forbid.
_ps_fixture_files() {
    ( shopt -s nullglob; printf '%s\n' "$FIX_DIR"/*.ansi )
}

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
#
# WHY THIS SUITE NEEDED IT (your-org/nexus-code#1171 skeptic blocker). This is
# the PRIMARY suite for `pane-state.sh`, and it declared no population — so it
# was one of the ~356 suites INVISIBLE to `guards-for-diff`: absent from
# `SELECTED` and from `CONSIDERED AND EXCLUDED` alike, hence indistinguishable
# from a considered exclusion. A change carrying the largest edit to
# `pane-state.sh` in that PR reported `13 of 13 selected guards PASS, exit 0`
# while THIS suite went red. That green was true and irrelevant — `#1078`
# exactly.
#
# The fixture directory is IN the population, and that is the load-bearing
# part rather than an afterthought: a fixture with no manifest row makes this
# suite RED, so ADDING A FILE HERE IS A CODE CHANGE to this suite's
# assertions. That is how the `#1171` blocker happened — a fixture landed
# whose name asserted the opposite of its purpose, and back then the name WAS
# the assertion. The manifest is in the population for the same reason: it is
# now where every expectation lives.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    _ps_fixture_files
    printf '%s\n' "$HELPER" "$MANIFEST"
}
gp_handle "$@"

# ===========================================================================
# fixture classification — expectations come from the MANIFEST, not the name
# ===========================================================================
#
# your-org/nexus-code#1176. Everything below is fail-CLOSED in both
# directions: an unruled fixture is RED (never SKIP, which is what `#896`
# could only turn into an unasserted capture), and a row naming a fixture that
# does not exist is RED too.

echo "=== manifest integrity ==="
[[ -r "$MANIFEST" ]] || { echo "manifest missing: $MANIFEST" >&2; exit 1; }

shopt -s nullglob
fixtures=()
while IFS= read -r _psf; do [[ -n "$_psf" ]] && fixtures+=("$_psf"); done < <( _ps_fixture_files )
(( ${#fixtures[@]} > 0 )) || { echo "no fixtures found" >&2; exit 1; }

manifest_rows=$(_ps_manifest_rows)
manifest_n=$(grep -c . <<<"$manifest_rows" || true)

# Non-degeneracy floor before ANY set comparison. Two empty enumerations
# compare EQUAL, which is the confident-zero shape this repo keeps meeting:
# a broken reader would read as "the manifest covers everything".
if (( manifest_n >= 40 )) && (( ${#fixtures[@]} >= 40 )); then
    printf '  PASS: enumerations are non-degenerate (%d manifest rows, %d fixtures; floor 40)\n' \
        "$manifest_n" "${#fixtures[@]}"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %d manifest rows / %d fixtures — enumeration is suspect, refusing to compare\n' \
        "$manifest_n" "${#fixtures[@]}" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Every row must have all five columns, a `why`, and an `expect` that
# `pane-state.sh` can actually produce. A typo in `expect` is a row that can
# never pass and never says why.
ps_states=$(bash "$HELPER" --states 2>/dev/null | sort)
[[ -n "$ps_states" ]] || { echo "pane-state.sh --states printed nothing" >&2; exit 1; }
malformed=0
while IFS=$'\t' read -r m_fix m_want m_env m_args m_why; do
    [[ -n "$m_fix" ]] || continue
    if [[ -z "$m_want" || -z "$m_env" || -z "$m_args" || -z "$m_why" ]]; then
        printf '    row for %q is missing a column (expect=%q env=%q args=%q why=%q)\n' \
            "$m_fix" "${m_want:-}" "${m_env:-}" "${m_args:-}" "${m_why:-}" >&2
        malformed=$(( malformed + 1 )); continue
    fi
    grep -qx -- "$m_want" <<<"$ps_states" || {
        printf '    row for %q expects %q, which is not in `pane-state.sh --states`\n' "$m_fix" "$m_want" >&2
        malformed=$(( malformed + 1 ))
    }
done <<<"$manifest_rows"
if (( malformed == 0 )); then
    printf '  PASS: every row is 5 columns, carries a rationale, and expects a declared state\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %d malformed manifest row(s) — see above\n' "$malformed" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Set equality, both directions, by BASENAME.
have_fix=$(for f in "${fixtures[@]}"; do basename "$f"; done | sort -u)
ruled_fix=$(cut -f1 <<<"$manifest_rows" | sort -u)
unruled=$(comm -23 <(printf '%s\n' "$have_fix") <(printf '%s\n' "$ruled_fix"))
stale=$(comm -13 <(printf '%s\n' "$have_fix") <(printf '%s\n' "$ruled_fix"))
if [[ -z "$unruled" ]]; then
    printf '  PASS: every fixture has at least one manifest row\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: fixture(s) with NO manifest row — a capture asserting nothing:\n%s\n' \
        "$(sed 's/^/    /' <<<"$unruled")" >&2
    printf '    → add a row to %s. It must say what the capture LOOKS like and\n' "$MANIFEST" >&2
    printf '      why the verdict is what it is. Do not rename the file instead.\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ -z "$stale" ]]; then
    printf '  PASS: every manifest row names a fixture that exists\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: manifest row(s) naming a fixture that does not exist:\n%s\n' \
        "$(sed 's/^/    /' <<<"$stale")" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Exactly ONE bare row per fixture. Zero is a capture only ever read under
# contrived conditions; two is two answers to one question.
bare_dupes=$(awk -F'\t' '$3 == "-" && $4 == "-" {print $1}' <<<"$manifest_rows" | sort | uniq -c \
             | awk '$1 != 1 {print $1" x "$2}')
bare_missing=$(comm -23 <(printf '%s\n' "$have_fix") \
                        <(awk -F'\t' '$3 == "-" && $4 == "-" {print $1}' <<<"$manifest_rows" | sort -u))
if [[ -z "$bare_dupes" && -z "$bare_missing" ]]; then
    printf '  PASS: every fixture has exactly one unconditional (bare) row\n'; PASS=$(( PASS + 1 ))
else
    [[ -n "$bare_missing" ]] && printf '  FAIL: fixture(s) with no BARE row:\n%s\n' "$(sed 's/^/    /' <<<"$bare_missing")" >&2
    [[ -n "$bare_dupes"   ]] && printf '  FAIL: fixture(s) with more than one BARE row:\n%s\n' "$(sed 's/^/    /' <<<"$bare_dupes")" >&2
    FAIL=$(( FAIL + 1 ))
fi

# --- the #1208 scenario harness -------------------------------------------
#
# Builds, for the manifest's `@…@` placeholders, a REAL reproduction of
# your-org/nexus-code#1208 rather than a description of one:
#
#   * a live process tree  shell -> `claude` -> background wait shell, whose
#     wait shell's argv is the `until [ -s "$T/status" ]; do sleep …; done`
#     loop the incident actually left behind — the async-run token is IN THE
#     ARGV, which is what makes it resolvable at all;
#   * an async-run ledger for that token whose verdict is `died`: a pid that
#     is gone, a recorded pidstart, and NO status file.
#
# The tree is the SAME for both rows; the ledger is the only variable. That is
# deliberate — a differential pair that varies one axis is the only shape whose
# green means what it says.
#
# Every process here is one this suite launched, is bounded by its own
# `sleep`, and is torn down by pid immediately after the loop.
_ps_h_dir=$(mktemp -d)
_ps_h_pid=""
_ps_async_state="$_ps_h_dir/state"
_ps_async_win=testwin          # == the `--name` assert_state passes, so a fix
                               # resolving by either channel finds the ledger
_ps_async_token=ar-abdb92e13667
# A SECOND token and tree, identical in every way except the ledger verdict:
# this one's pid is alive with a matching start-time, so async-run says
# `running`. It is both the authority probe and the non-vacuity control, and
# it makes the VERDICT the single axis the differential varies. The first cut
# of this harness varied the presence of `NEXUS_STATE_DIR` in the environment
# instead -- which is not the axis the fix keys on: the wait wrapper's argv
# carries an ABSOLUTE token path, so resolution works with no async-run
# environment at all. That is why the live incident resolved from a watcher
# process that had never heard of the window.
_ps_run_token=ar-0123456789ab
_ps_h_pid2=""
_ps_run_pid=""
_ps_harness_ok=0
if command -v pgrep >/dev/null 2>&1 && [[ -r /proc/$$/stat ]]; then
    _ps_bash_bin=$(command -v bash)
    if cp "$_ps_bash_bin" "$_ps_h_dir/claude" 2>/dev/null; then
        # `wk_encode` is the injective window-key encoder every window-keyed
        # surface uses (#941); async-run resolves its directory with it, so the
        # ledger must be written under the same key rather than a guess.
        . "$_repo_root/monitor/_bookkeeping.sh" 2>/dev/null || true
        if declare -F wk_encode >/dev/null 2>&1; then
            _ps_tokdir="$_ps_async_state/async-run/$(wk_encode "$_ps_async_win")/$_ps_async_token"
            mkdir -p "$_ps_tokdir"
            # A pid that is gone, with a recorded start-time so the verdict is
            # `died` (killed before writing status) and not `running`.
            echo 4194303 > "$_ps_tokdir/pid"
            echo 1        > "$_ps_tokdir/pidstart"
            echo 1        > "$_ps_tokdir/started"
            "$_ps_h_dir/claude" -c "bash -c 'T=$_ps_tokdir; until [ -s \"\$T/status\" ]; do sleep 30; done' & sleep 240" \
                >/dev/null 2>&1 &
            _ps_h_pid=$!

            # The `running` sibling: a real, self-bounding process of ours,
            # with its real /proc start-time recorded, so async-run's pid
            # IDENTITY check passes and the verdict is genuinely `running`.
            sleep 240 >/dev/null 2>&1 &
            _ps_run_pid=$!
            _ps_runtokdir="$_ps_async_state/async-run/$(wk_encode "$_ps_async_win")/$_ps_run_token"
            mkdir -p "$_ps_runtokdir"
            echo "$_ps_run_pid" > "$_ps_runtokdir/pid"
            awk '{print $22}' "/proc/$_ps_run_pid/stat" 2>/dev/null > "$_ps_runtokdir/pidstart"
            echo 1 > "$_ps_runtokdir/started"
            "$_ps_h_dir/claude" -c "bash -c 'T=$_ps_runtokdir; until [ -s \"\$T/status\" ]; do sleep 30; done' & sleep 240" \
                >/dev/null 2>&1 &
            _ps_h_pid2=$!
            # Wait for the child shell to exist rather than sleeping blind.
            for _ps_i in $(seq 1 100); do
                [[ -n "$(pgrep -P "$_ps_h_pid" 2>/dev/null)" ]] \
                  && [[ -n "$(pgrep -P "$_ps_h_pid2" 2>/dev/null)" ]] && break
                sleep 0.3
            done
            _ps_harness_ok=1
        fi
    fi
fi
if (( _ps_harness_ok == 1 )); then
    # The harness must be measured, not assumed: `bg_reliable=1` is what says
    # the process-tree walk was authoritative. Without it the footer fallback
    # would drive the verdict and both scenario rows would be reading the
    # fixture's `1 shell` footer instead of the tree they were built for.
    # Probe the RUNNING tree, not the dead one. `bg_shells=`/`bg_reliable=`
    # ride only on a `working-background` emit, so probing the dead tree would
    # conflate "the walk was not authoritative" with "the fix correctly stopped
    # calling this work in flight" -- and would report the FIX as a broken
    # harness. The running tree is authoritative AND still working-background,
    # so it separates the two.
    _ps_probe=$("$HELPER" --fixture "$FIX_DIR/wrapped-up-one-shell-dead-async-1208.ansi" \
                          --window 9 --name testwin --active 0 --pane-pid "$_ps_h_pid2" 2>&1)
    if grep -q 'bg_reliable=1' <<<"$_ps_probe" && grep -q 'bg_shells=1' <<<"$_ps_probe"; then
        printf '  PASS: #1208 harness built an authoritative tree (bg_shells=1 bg_reliable=1)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: #1208 harness tree not authoritative — the scenario rows below would read the FOOTER, not the tree (got: %s)\n' \
            "$_ps_probe" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    _ps_rverdict=$(NEXUS_STATE_DIR="$_ps_async_state" NEXUS_WORKER_WINDOW="$_ps_async_win" \
                  bash "$_repo_root/monitor/async-run.sh" --status-line "$_ps_run_token" 2>&1)
    if [[ "$_ps_rverdict" == running\|* ]]; then
        printf '  PASS: #1208 harness control ledger reports `running` for %s\n' "$_ps_run_token"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: #1208 harness CONTROL verdict is %q, want running|… — the non-vacuity control is vacuous\n' \
            "$_ps_rverdict" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # And the ledger must actually say `died`, or the row below asks nothing.
    _ps_verdict=$(NEXUS_STATE_DIR="$_ps_async_state" NEXUS_WORKER_WINDOW="$_ps_async_win" \
                  bash "$_repo_root/monitor/async-run.sh" --status-line "$_ps_async_token" 2>&1)
    if [[ "$_ps_verdict" == died\|* ]]; then
        printf '  PASS: #1208 harness ledger reports `died` for %s\n' "$_ps_async_token"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: #1208 harness ledger verdict is %q, want died|… — the scenario row is vacuous\n' \
            "$_ps_verdict" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  FAIL: could not build the #1208 harness (pgrep/proc/wk_encode unavailable) — refusing to report its rows as green\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# Placeholder expansion. An unrecognised `@NAME@` is RED rather than passed
# through as a literal: a silently-unexpanded placeholder becomes a filename
# nothing reads, and the row then measures the bare case while claiming a
# scenario.
_ps_expand() {
    local v="$1"
    v="${v//@ASYNC_STATE@/$_ps_async_state}"
    v="${v//@ASYNC_WIN@/$_ps_async_win}"
    v="${v//@ASYNC_TOKEN@/$_ps_async_token}"
    v="${v//@BG_WAIT_PANE_PID@/$_ps_h_pid}"
    v="${v//@BG_RUN_PANE_PID@/$_ps_h_pid2}"
    printf '%s' "$v"
}

echo
echo "=== fixture classification (manifest-driven) ==="
checked=0
while IFS=$'\t' read -r m_fix m_want m_env m_args m_why; do
    [[ -n "$m_fix" && -n "$m_want" ]] || continue
    [[ -f "$FIX_DIR/$m_fix" ]] || continue   # already RED above as a stale row
    row_env=(); row_args=()
    if [[ "$m_env" != "-" ]]; then
        read -r -a row_env <<<"$(_ps_expand "$m_env")"
    fi
    if [[ "$m_args" != "-" ]]; then
        read -r -a row_args <<<"$(_ps_expand "$m_args")"
    fi
    # Herestring, not a pipe: under this file's `set -uo pipefail` a `grep -q`
    # that matches early closes the pipe and the producer takes SIGPIPE, so
    # pipefail reports 141 and the `if` silently takes the ELSE arm — here that
    # means an UNEXPANDED PLACEHOLDER passes the screen (#1214). These two
    # values are short enough that today it does not fire, which is exactly why
    # the form must not be left in place: the safety is accidental, and it ends
    # the day a manifest row grows past the pipe buffer.
    if grep -q '@[A-Z_]*@' <<<"${row_env[*]:-} ${row_args[*]:-}"; then
        printf '  FAIL: %s — unexpanded placeholder in env/args (%s | %s)\n' \
            "$m_fix" "${row_env[*]:-}" "${row_args[*]:-}" >&2
        FAIL=$(( FAIL + 1 )); continue
    fi
    checked=$(( checked + 1 ))
    assert_state "$FIX_DIR/$m_fix" "$m_want" "${row_env[@]}" -- "${row_args[@]}"
done <<<"$manifest_rows"

# A vanished loop body is a green suite that asserted nothing (#807). Pin the
# count against the row count the manifest itself declares.
if (( checked == manifest_n )); then
    printf '  PASS: every one of the %d manifest rows was exercised\n' "$checked"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: exercised %d of %d manifest rows — assertions went missing\n' "$checked" "$manifest_n" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Tear the harness down by PID — processes this suite launched, nothing else.
for _ps_victim in "$_ps_h_pid" "$_ps_h_pid2" "$_ps_run_pid"; do
    [[ -n "$_ps_victim" ]] || continue
    pkill -P "$_ps_victim" >/dev/null 2>&1 || true
    kill "$_ps_victim" >/dev/null 2>&1 || true
    wait "$_ps_victim" 2>/dev/null || true
done
rm -rf "$_ps_h_dir"

echo
echo "=== output format ==="
out=$("$HELPER" --fixture "${fixtures[0]}" --window 42 --name myname --active 1)
for key in state active window name; do
    if grep -qE "(^| )${key}=" <<<"$out"; then
        printf '  PASS: output contains %s=...\n' "$key"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: output missing key %s (got: %s)\n' "$key" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done
if grep -q 'window=42' <<<"$out" && grep -q 'name=myname' <<<"$out" && grep -q 'active=1' <<<"$out"; then
    printf '  PASS: --window/--name/--active passthrough\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: --window/--name/--active passthrough (got: %s)\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== heartbeat substrate (issue #74) ==="
# These exercise the new worker-side heartbeat path. We pin a temp
# state-dir, write a JSON heartbeat for a known window name, and
# point pane-state.sh at it via --heartbeat-file / --window /
# --name. The renderer fixture is a passive idle-empty so any
# fall-through emits `idle` and we can prove the heartbeat
# overrode (or correctly didn't override) it.
hb_tmp=$(mktemp -d)
trap 'rm -rf "$hb_tmp"' EXIT
hb_file="$hb_tmp/test.json"
idle_fixture="$FIX_DIR/idle-empty-synthetic.ansi"
[[ -f "$idle_fixture" ]] || { echo "heartbeat tests need $idle_fixture" >&2; exit 1; }

# Pinned `now` so the test is hermetic — no real-time skew.
NOW=2000000000

assert_heartbeat_state() {
    local label="$1" want="$2" hb_state="$3" age="$4"; shift 4
    local extra=("$@")
    local last_activity=$(( NOW - age ))
    printf '{"state":"%s","last_activity":%s,"window":"test"}\n' \
        "$hb_state" "$last_activity" > "$hb_file"
    local out got
    out=$("$HELPER" --fixture "$idle_fixture" \
                    --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" \
                    --now "$NOW" \
                    "${extra[@]}" 2>&1) || {
        printf '  FAIL: %s — helper exited nonzero: %s\n' "$label" "$out" >&2
        FAIL=$(( FAIL + 1 ))
        return
    }
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %-55s state=%s\n' "$label" "$got"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %-55s got=%s want=%s (full: %s)\n' \
            "$label" "$got" "$want" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# Fresh heartbeat overrides the renderer.
assert_heartbeat_state "fresh busy → busy"                    busy    busy              5
assert_heartbeat_state "fresh user_prompt → busy"             busy    user_prompt       5
assert_heartbeat_state "fresh permission_prompt → blocked"    blocked permission_prompt 5
assert_heartbeat_state "fresh idle_prompt → idle"             idle    idle_prompt       5

# Stale heartbeat (older than default 30 s) falls through to renderer.
assert_heartbeat_state "stale busy → falls through to renderer (idle)" idle busy 31

# Custom staleness window: 10 s. A 15 s-old heartbeat is now stale.
assert_heartbeat_state "stale w/ --heartbeat-staleness 10 → idle"      idle busy 15 \
    --heartbeat-staleness 10
# Same age, default (30 s) staleness — fresh, busy.
assert_heartbeat_state "fresh w/ default staleness, age 15 → busy"     busy busy 15

# Unmapped state in the file: fall through.
printf '{"state":"weird","last_activity":%s,"window":"test"}\n' "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: unmapped heartbeat state falls through (state=idle)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: unmapped heartbeat state — got=%s want=idle\n' "$got" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Malformed JSON: fall through.
echo "not actually json" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: malformed heartbeat JSON falls through (state=idle)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: malformed heartbeat — got=%s want=idle\n' "$got" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Missing file: fall through.
rm -f "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: missing heartbeat file falls through (state=idle)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: missing heartbeat — got=%s want=idle\n' "$got" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== heartbeat overrides busy-mid-render fixture ==="
# The busy-mid-render fixture has no chevron at all — without a
# heartbeat, pane-state has to infer busy from the spinner token
# counter. With a fresh `idle_prompt` heartbeat, the heartbeat wins.
mid_render_fixture="$FIX_DIR/busy-mid-render-no-chevron-synthetic.ansi"
if [[ -f "$mid_render_fixture" ]]; then
    printf '{"state":"idle_prompt","last_activity":%s,"window":"test"}\n' "$NOW" > "$hb_file"
    out=$("$HELPER" --fixture "$mid_render_fixture" --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "idle" ]]; then
        printf '  PASS: fresh idle_prompt heartbeat overrides busy-mid-render → idle\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: heartbeat override — got=%s want=idle\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # And the inverse: stale heartbeat lets the renderer's busy
    # detection through.
    printf '{"state":"idle_prompt","last_activity":1,"window":"test"}\n' > "$hb_file"
    out=$("$HELPER" --fixture "$mid_render_fixture" --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "busy" ]]; then
        printf '  PASS: stale heartbeat → renderer reclaims busy-mid-render → busy\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: stale heartbeat fall-through — got=%s want=busy\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

echo
echo "=== heartbeat-idle refined by renderer typing (issue #196) ==="
# A fresh `idle_prompt` heartbeat proves the agent's turn ended but
# cannot see the operator typing into the input box afterwards. The
# heartbeat-idle verdict must be refined to `user-typing` when the
# renderer shows the bright-text marker; autosuggest ghost text (dim
# only) must NOT refine; a busy heartbeat is untouched.
typing_fixture="$FIX_DIR/user-typing-synthetic.ansi"
autosuggest_fixture="$FIX_DIR/autosuggest-merge-win3.ansi"
if [[ -f "$typing_fixture" && -f "$autosuggest_fixture" ]]; then
    printf '{"state":"idle_prompt","last_activity":%s,"window":"test"}\n' "$NOW" > "$hb_file"
    out=$("$HELPER" --fixture "$typing_fixture" --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "user-typing" ]]; then
        printf '  PASS: idle heartbeat + bright input row → user-typing\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: idle heartbeat + typing fixture — got=%s want=user-typing\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    out=$("$HELPER" --fixture "$autosuggest_fixture" --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "idle" ]]; then
        printf '  PASS: idle heartbeat + autosuggest ghost stays idle\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: idle heartbeat + autosuggest — got=%s want=idle\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    printf '{"state":"busy","last_activity":%s,"window":"test"}\n' "$NOW" > "$hb_file"
    out=$("$HELPER" --fixture "$typing_fixture" --window 9 --name test --active 0 \
                    --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "busy" ]]; then
        printf '  PASS: busy heartbeat unaffected by typing refinement\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: busy heartbeat + typing fixture — got=%s want=busy\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  SKIP: typing/autosuggest fixtures missing\n'
fi

echo
echo "=== last_turn_end staleness (Stop-hook idle, #129 item 3) ==="
# A turn_end-derived heartbeat carries BOTH last_activity and
# last_turn_end. The classifier should use last_turn_end as the
# staleness anchor and apply the longer threshold — proving that
# Stop-derived idle survives past the 30 s `last_activity` window.

# 1. Fresh turn_end (both anchors current) → idle.
printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s,"window":"test"}\n' \
    "$NOW" "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: turn_end heartbeat (fresh both anchors) → idle\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: turn_end fresh → idle — got=%s\n' "$got" >&2; FAIL=$(( FAIL + 1 ))
fi

# 2. last_activity stale (>30 s), last_turn_end fresh → idle.
#    This is the load-bearing case: without the last_turn_end anchor
#    the heartbeat would go stale and pane-state would fall through
#    to the renderer. With it, the Stop-derived idle survives.
old_la=$(( NOW - 600 ))
printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s,"window":"test"}\n' \
    "$old_la" "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: last_activity stale (10min), last_turn_end fresh → idle (anchor swap working)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: last_activity stale + last_turn_end fresh — got=%s want=idle\n' "$got" >&2; FAIL=$(( FAIL + 1 ))
fi

# 3. last_turn_end older than its longer threshold (1800 s default) →
#    classifier returns 1 → fall through to renderer (idle on the
#    idle-empty fixture). Proves the longer threshold isn't infinite.
ancient_lte=$(( NOW - 3600 ))
printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s,"window":"test"}\n' \
    "$NOW" "$ancient_lte" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
# Anchor swap puts us on the stale last_turn_end → fall through →
# renderer says idle on the idle-empty fixture. The renderer verdict
# is the same emit value, but it's reached via the renderer path,
# not the heartbeat path. Hard to assert "took which path" from the
# emit alone, so this test guards against a regression where the
# anchor swap forgot the threshold check entirely and returned `idle`
# from an arbitrarily-old stamp.
if [[ "$got" == "idle" ]]; then
    printf '  PASS: turn_end older than 1800 s threshold → falls through (renderer also says idle)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: turn_end > threshold expected idle (renderer), got=%s\n' "$got" >&2; FAIL=$(( FAIL + 1 ))
fi

# 4. Custom --heartbeat-turn-end-staleness wins. With threshold=60,
#    a 120 s-old last_turn_end is stale → fall-through.
old_lte=$(( NOW - 120 ))
printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s,"window":"test"}\n' \
    "$NOW" "$old_lte" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" \
                --heartbeat-turn-end-staleness 60 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: --heartbeat-turn-end-staleness 60 honored (120s old → stale → renderer fallback)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: turn_end staleness override — got=%s\n' "$got" >&2; FAIL=$(( FAIL + 1 ))
fi

# 5. busy heartbeat MUST NOT receive the turn_end longer threshold
#    even if some buggy caller injects last_turn_end into a non-idle
#    state. The classifier still picks last_turn_end as the anchor
#    (anchor selection is field-presence-based, not state-based) —
#    that's the contract. Document this so a future change doesn't
#    silently make busy heartbeats survive 30 min of silence.
old_la2=$(( NOW - 60 ))
printf '{"state":"busy","last_activity":%s,"last_turn_end":%s,"window":"test"}\n' \
    "$old_la2" "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "busy" ]]; then
    printf '  PASS: anchor selection is field-presence-based (busy+last_turn_end → busy emit; contract documented)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: malformed busy+last_turn_end → busy expected, got=%s\n' "$got" >&2; FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== PermissionRequest hook → state=blocked (end-to-end, #129 item 2) ==="
# Exercise the full hook → heartbeat → pane-state classification chain
# for the PermissionRequest hook block in monitor/worker-settings.json.
# The hook command is `$NEXUS_ROOT/monitor/worker-heartbeat.sh
# permission_prompt` — fire the helper exactly the way the hook
# would, then read the resulting heartbeat through pane-state.sh and
# assert the renderer-fallback regex `_has_blocked_overlay` did NOT
# need to run (the heartbeat alone produced `state=blocked`).
#
# This complements the existing `fresh permission_prompt → blocked`
# unit (which writes a JSON file directly) and PR #131's "What
# Remains" regression-test item: prove the per-spawn hook config
# lands the correct heartbeat without depending on the rendered
# permission overlay.
hb_e2e_dir=$(mktemp -d)
HEARTBEAT_HELPER="$_repo_root/monitor/worker-heartbeat.sh"
env -i PATH="$PATH" \
    NEXUS_STATE_DIR="$hb_e2e_dir" NEXUS_WORKER_WINDOW=permreq-test \
    bash "$HEARTBEAT_HELPER" permission_prompt \
    <<<'{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
    >/dev/null 2>&1
hb_e2e_file="$hb_e2e_dir/heartbeat/permreq-test.json"
if [[ -f "$hb_e2e_file" ]]; then
    # Verify the heartbeat itself carries the expected state.
    hb_state_token=$(jq -r '.state // empty' "$hb_e2e_file" 2>/dev/null)
    if [[ "$hb_state_token" == "permission_prompt" ]]; then
        printf '  PASS: PermissionRequest hook fire → heartbeat state=permission_prompt\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: PermissionRequest hook fire — heartbeat state=%s want=permission_prompt\n' "$hb_state_token" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # And classifier emit: the idle-empty fixture would normally yield
    # `idle`. The fresh permission_prompt heartbeat must override to
    # `blocked` without consulting the renderer's overlay regex.
    out=$("$HELPER" --fixture "$idle_fixture" \
                    --window 9 --name permreq-test --active 0 \
                    --heartbeat-file "$hb_e2e_file" \
                    --now "$(date +%s)" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "blocked" ]]; then
        printf '  PASS: pane-state reads fresh heartbeat → state=blocked (renderer overlay regex not exercised)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: pane-state heartbeat → blocked — got=%s (full: %s)\n' "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  FAIL: PermissionRequest hook fire produced no heartbeat at %s\n' "$hb_e2e_file" >&2
    FAIL=$(( FAIL + 1 ))
fi
rm -rf "$hb_e2e_dir"

echo
echo "=== over-limit stamp file (StopFailure hook, #129 item 4) ==="
# Hook-driven over-limit detection: when the StopFailure handler has
# written $STATE_DIR/over-limit/<window>.json, pane-state must emit
# state=over-limit + reset_at directly, without scanning the rendered
# pane for the "You've hit your limit · resets" text. The file path
# is also overridable via --over-limit-file for hermetic tests.

ol_tmp=$(mktemp)
ol_idle_fixture="$FIX_DIR/idle-empty-synthetic.ansi"
[[ -f "$ol_idle_fixture" ]] || { echo "needs $ol_idle_fixture" >&2; exit 1; }

# 1. File present with reset_at populated → emit state=over-limit
#    reset_at=<token>. `ts` must be FRESH: stamps older than the
#    anti-latch TTL (default 27h) are ignored + deleted by design.
printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","error_message":"weekly Opus limit","reset_at":"3am (America/Los_Angeles)","window":"olwin","hook_event_name":"StopFailure"}\n' \
    "$(date +%s)" > "$ol_tmp"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
got_reset=$(grep -oE 'reset_at=[^ ]+' <<<"$out" | sed 's/^reset_at=//')
if [[ "$got_state" == "over-limit" ]]; then
    printf '  PASS: over-limit file present → state=over-limit (renderer scrape not exercised)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: over-limit file → state — got=%s want=over-limit (full: %s)\n' "$got_state" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi
# Reset normalisation mirrors the renderer's: parens stripped, whitespace → _.
if [[ "$got_reset" == "3am_America/Los_Angeles" ]]; then
    printf '  PASS: reset_at normalised (got %s)\n' "$got_reset"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: reset_at normalisation — got=%s want=3am_America/Los_Angeles\n' "$got_reset" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 2. File present with reset_at:null → emit state=over-limit
#    reset_at=unknown. Documents the documented-blocked path the
#    handler takes when no reset_at field was extractable from the
#    StopFailure payload.
printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","reset_at":null,"window":"olwin","hook_event_name":"StopFailure"}\n' \
    "$(date +%s)" > "$ol_tmp"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
got_reset=$(grep -oE 'reset_at=[^ ]+' <<<"$out" | sed 's/^reset_at=//')
if [[ "$got_state" == "over-limit" ]] && [[ "$got_reset" == "unknown" ]]; then
    printf '  PASS: over-limit file + reset_at:null → state=over-limit reset_at=unknown\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: over-limit reset_at:null — state=%s reset_at=%s\n' "$got_state" "$got_reset" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 3. A fresh busy heartbeat wins over the over-limit stamp — by
#    design. PostToolUse just fired ⇒ the worker IS doing real work
#    again ⇒ the rate limit has lifted (or the stamp is stale).
#    The Stop hook will clear the stamp on the next turn-end, so we
#    don't need to clear it pre-emptively; just let the heartbeat
#    speak. This documents the ordering: heartbeat (busy/idle/
#    blocked) before over-limit-stamp before over-limit-text. The
#    reverse would have a resumed worker stuck classifying as
#    over-limit until the Stop hook fired again.
# ts is pinned near the frozen $NOW these sub-tests pass via --now,
# so the stamp reads FRESH relative to the injected clock.
printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","reset_at":"3am","window":"olwin","hook_event_name":"StopFailure"}\n' \
    "$(( NOW - 60 ))" > "$ol_tmp"
printf '{"state":"busy","last_activity":%s,"window":"olwin"}\n' "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" == "busy" ]]; then
    printf '  PASS: fresh busy heartbeat wins over stale over-limit stamp (resumed worker)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: heartbeat-over-stamp precedence — got=%s want=busy\n' "$got_state" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 3b. The load-bearing inverse: STALE heartbeat + over-limit stamp →
#     emit over-limit. The 30 s last_activity threshold expires, the
#     classifier returns 1 (no heartbeat match), the renderer-blocked
#     overlay check finds nothing on the idle-empty fixture, and the
#     over-limit-stamp check fires. Demonstrates the stamp is
#     consulted when the heartbeat doesn't fire.
old_la=$(( NOW - 600 ))
printf '{"state":"busy","last_activity":%s,"window":"olwin"}\n' "$old_la" > "$hb_file"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" == "over-limit" ]]; then
    printf '  PASS: stale heartbeat + over-limit stamp → state=over-limit\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: stale heartbeat + over-limit stamp — got=%s want=over-limit\n' "$got_state" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 3c. Blocked-overlay precedence over the over-limit stamp — load-
#     bearing for the brief's "case-B cascade MUST still fire"
#     constraint. When the rate-limit menu is up AND the over-limit
#     stamp is present, pane-state must emit state=blocked so
#     _unstick.sh case B can fire its auto-Enter cascade. Once the
#     menu is dismissed (no overlay text), the stamp takes over.
# TWO defects in one line, both fixed here (your-org/nexus-code#1214 D1).
#
# (a) NULLGLOB + A COMMAND WITH A MEANINGFUL BARE FORM. This read
#     `ls "$FIX_DIR"/blocked-*.ansi 2>/dev/null | head -1`. `shopt -s nullglob`
#     is set FILE-WIDE at line 115 -- NOT the subshell-scoped
#     `( shopt -s nullglob; … )` at line 75, which an earlier version of this
#     comment cited and which does NOT reach here. The wrong line pointed at
#     the wrong CONCLUSION, not merely a wrong number: a reader sent to 75
#     would have decided the hazard was contained to a subshell. So when the
#     glob matches NOTHING it
#     VANISHES rather than staying literal -- `ls` then runs BARE, lists the
#     CURRENT WORKING DIRECTORY, and `head -1` takes its first entry. Measured:
#     the assertion ran against CHANGELOG.md. The honest `else` SKIP branch below
#     is unreachable whenever the cwd is non-empty, which it always is.
#     The general shape, worth grepping for beyond this file because nullglob is
#     a repo-wide convention here: A GLOB THAT CAN LEGITIMATELY MATCH NOTHING,
#     FEEDING A COMMAND THAT DOES SOMETHING MEANINGFUL WITH NO ARGUMENTS
#     (`ls`/`du` act on the cwd; `cat`/`grep`/`wc` read stdin). Six such sites
#     across four files at this commit -- see the PR.
#
# (b) A FIFTH FILENAME-DERIVED EXPECTATION. `blocked-*` picks the fixture BY
#     NAME and then asserts it classifies as `blocked` -- the scheme `#1176`
#     removes, in the file that removes it, for the fourth time on this branch.
#
# The manifest answers both: it names the fixture, so no glob, and it carries
# the expectation, so no prefix. A bash loop, not `$(...)`, so there is no
# command with a bare form to fall back to.
blocked_fixture=""
while IFS=$'\t' read -r _bf _bw _be _ba _br; do
    [[ "$_bw" == "blocked" && "$_be" == "-" && "$_ba" == "-" ]] || continue
    [[ -f "$FIX_DIR/$_bf" ]] || continue
    blocked_fixture="$FIX_DIR/$_bf"; break
done <<<"$manifest_rows"
if [[ -n "$blocked_fixture" ]]; then
    out=$("$HELPER" --fixture "$blocked_fixture" --window 9 --name olwin --active 0 \
                    --over-limit-file "$ol_tmp" \
                    --heartbeat-file /dev/null --now "$NOW" 2>&1)
    got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got_state" == "blocked" ]]; then
        printf '  PASS: blocked-overlay wins over over-limit stamp (case-B cascade preserved)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: blocked vs stamp precedence — got=%s want=blocked (fixture: %s)\n' "$got_state" "$(basename "$blocked_fixture")" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  SKIP: no blocked-*.ansi fixture available for case-B precedence check\n'
fi

# 4. Missing over-limit file → fall through to heartbeat / renderer.
#    Empty --over-limit-file flag would mis-interpret as "use blank
#    path", but the override only kicks in when non-empty; absent or
#    empty falls through to the env-var resolved path, which (with
#    NEXUS_STATE_DIR unset in this test process) yields no lookup.
rm -f "$ol_tmp"
printf '{"state":"idle_prompt","last_activity":%s,"window":"olwin"}\n' "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file "$hb_file" --now "$NOW" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" == "idle" ]]; then
    printf '  PASS: missing over-limit file → falls through (heartbeat → idle)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: missing over-limit file — got=%s want=idle\n' "$got_state" >&2
    FAIL=$(( FAIL + 1 ))
fi

rm -f "$ol_tmp"

# 5. Anti-latch TTL (2026-07-14 incident follow-up): a stamp whose
#    `ts` is older than MONITOR_OVER_LIMIT_STAMP_TTL_SECONDS (default
#    27h) is EXPIRED — ignored, best-effort deleted, and the
#    classifier falls through to the renderer. The stamp's cleanup
#    contract ("Stop hook clears it on the next successful turn")
#    has no successful turn to ride when a pane's settings lost the
#    Stop entry; without the TTL that pane reads over-limit forever
#    and the watcher's emit gate latches shut.
stale_ts=$(( NOW - 100 * 3600 ))   # 100h old ≫ 27h TTL
printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","reset_at":"3am","window":"olwin","hook_event_name":"StopFailure"}\n' \
    "$stale_ts" > "$ol_tmp"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file /dev/null --now "$NOW" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" != "over-limit" ]]; then
    printf '  PASS: expired stamp (100h) ignored → state=%s (no latch)\n' "$got_state"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: expired stamp still classifies over-limit — the latch the TTL exists to prevent\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ ! -f "$ol_tmp" ]]; then
    printf '  PASS: expired stamp deleted (self-cleaning)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: expired stamp not deleted\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# 5b. TTL boundary: a stamp INSIDE the TTL still classifies
#     over-limit (the TTL must not eat live suspensions).
printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","reset_at":"3am","window":"olwin","hook_event_name":"StopFailure"}\n' \
    "$(( NOW - 20 * 3600 ))" > "$ol_tmp"   # 20h old < 27h TTL
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file /dev/null --now "$NOW" 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" == "over-limit" ]]; then
    printf '  PASS: 20h-old stamp (inside TTL) still over-limit\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: inside-TTL stamp lost — got=%s want=over-limit\n' "$got_state" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 5c. Corrupt stamp (no parseable ts, ancient mtime) ages out via
#     the mtime fallback instead of latching.
printf 'not json at all\n' > "$ol_tmp"
touch -d '@1700000000' "$ol_tmp" 2>/dev/null || touch -t 202311140000 "$ol_tmp"
out=$("$HELPER" --fixture "$ol_idle_fixture" --window 9 --name olwin --active 0 \
                --over-limit-file "$ol_tmp" \
                --heartbeat-file /dev/null 2>&1)
got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got_state" != "over-limit" ]]; then
    printf '  PASS: corrupt ancient stamp ages out via mtime (got %s)\n' "$got_state"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: corrupt ancient stamp latched over-limit\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

rm -f "$ol_tmp"

echo
echo "=== over-limit detection (issue #87) ==="
# Canonical fixture: emits reset_at=<token> alongside state=over-limit.
canonical_fixture="$FIX_DIR/over-limit-canonical-synthetic.ansi"
if [[ -f "$canonical_fixture" ]]; then
    out=$("$HELPER" --fixture "$canonical_fixture" --window 9 --name overw --active 0)
    if grep -q 'state=over-limit' <<<"$out" \
       && grep -q 'reset_at=3am_America/Los_Angeles' <<<"$out"; then
        printf '  PASS: canonical over-limit emits reset_at=3am_America/Los_Angeles\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: canonical over-limit emit (got: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# Terse variant: bare time, no timezone parenthetical.
terse_fixture="$FIX_DIR/over-limit-terse-synthetic.ansi"
if [[ -f "$terse_fixture" ]]; then
    out=$("$HELPER" --fixture "$terse_fixture" --window 9 --name overw --active 0)
    if grep -q 'state=over-limit' <<<"$out" \
       && grep -q 'reset_at=11pm' <<<"$out"; then
        printf '  PASS: terse over-limit emits reset_at=11pm\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: terse over-limit emit (got: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# False-positive guard: idle pane whose scrollback contains the canonical
# text. Detection is anchored to the bottom 15 rows so this MUST emit idle.
fp_fixture="$FIX_DIR/idle-overlimit-text-in-scrollback-synthetic.ansi"
if [[ -f "$fp_fixture" ]]; then
    out=$("$HELPER" --fixture "$fp_fixture" --window 9 --name overw --active 0)
    if grep -q 'state=idle' <<<"$out" && ! grep -q 'state=over-limit' <<<"$out"; then
        printf '  PASS: over-limit text in scrollback does not false-trigger\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: scrollback over-limit text false-triggered (got: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# Hand-crafted fixture: notice text without a "resets <time>" companion.
# Detector requires both keys, so this should fall through to absent
# (no chevron, no spinner, no live claude in fixture mode).
no_reset_tmp=$(mktemp)
printf "Some random output\nYou've hit your limit (no reset line)\nmore text\n" > "$no_reset_tmp"
out=$("$HELPER" --fixture "$no_reset_tmp" --window 9 --name overw --active 0)
if ! grep -q 'state=over-limit' <<<"$out"; then
    printf '  PASS: half-rendered notice (no resets companion) does not over-trigger\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: half-rendered notice over-triggered (got: %s)\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi
rm -f "$no_reset_tmp"

echo
echo "=== over-limit banner STRUCTURE, not substring (your-org/nexus-code#571) ==="
# The detector must test the banner's structure — a clean lead-in plus a
# contiguous "resets <time>" companion — not mere substring presence. Two
# controls, each a genuine DIFFERENTIAL against a prior detector, so neither
# can pass vacuously (skeptic standard: a gate never seen fail is not evidence).
#
# Shared strip+bottom pipeline, mirroring pane-state's production path
# (_strip_ansi | _bottom_rows 15), so the differential greps below see exactly
# the text _detect_over_limit sees.
_ol_bottom_rows() {   # <fixture-path> -> stripped, blank-culled bottom 15 rows
    sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' <"$1" | grep -v '^[[:space:]]*$' | tail -n 15
}
# The two historical headline patterns this fix supersedes.
_OL_DEV_HEADLINE='You.{0,3}ve (hit|reached) your ([[:alnum:]-]+ ){0,2}limit'
_OL_591_HEADLINE='^[[:space:]]*You.{0,3}ve (hit|reached) your ([[:alnum:]-]+ ){0,2}limit'

# POSITIVE control — the retry-exhaustion render captured from CI
# (run 30567702742): the headline sits MID-LINE, prefixed by the client's
# `● API Error: Request rejected (429) · ` decoration. This is the arm #591's
# bare `^[[:space:]]*` anchor silently BLINDED the detector to — an invisible
# miss on the render the repo's own real-binary test treats as a true positive.
apierror_fixture="$FIX_DIR/over-limit-apierror-midline-synthetic.ansi"
if [[ -f "$apierror_fixture" ]]; then
    out=$("$HELPER" --fixture "$apierror_fixture" --window 9 --name overw --active 0)
    if grep -q 'state=over-limit' <<<"$out" \
       && grep -q 'reset_at=3am_America/Los_Angeles' <<<"$out"; then
        printf '  PASS: API-error mid-line banner parks (reset_at parsed)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: API-error mid-line banner did NOT park (got: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # Differential proof this control is load-bearing: #591's line-start anchor
    # MISSES this exact row. Assert on the discriminating fact (the reverted
    # anchor's behaviour), not just our own green — so a future re-introduction
    # of `^[[:space:]]*` is caught here with a named reason.
    _bot=$(_ol_bottom_rows "$apierror_fixture")
    if grep -qE "$_OL_591_HEADLINE" <<<"$_bot"; then
        printf '  FAIL: expected #591 line-start anchor to MISS the API-error row, but it matched — control is not a differential\n' >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: #591 line-start anchor misses this row (why the anchor was reverted)\n'
        PASS=$(( PASS + 1 ))
    fi
fi

# NEGATIVE control — a healthy, idle worker whose pane QUOTES the notice as
# message content (`● user pasted: "You've hit your weekly limit · resets …"`)
# INSIDE the bottom-15 window. Position alone does NOT save it here (unlike the
# scrollback fixture above); the CLEAN-LEAD-IN gate must. Must classify idle.
quoted_fixture="$FIX_DIR/idle-overlimit-quoted-relay-bottomrows-synthetic.ansi"
if [[ -f "$quoted_fixture" ]]; then
    out=$("$HELPER" --fixture "$quoted_fixture" --window 9 --name overw --active 0)
    if ! grep -q 'state=over-limit' <<<"$out" && grep -q 'state=idle' <<<"$out"; then
        printf '  PASS: bulleted quote in bottom rows does NOT park (lead-in gate)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: bulleted quote in bottom rows false-parked (got: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # Differential proof this control exercises the LEAD-IN gate, not position:
    # the OLD two-grep detector (headline anywhere + resets anywhere) WOULD have
    # parked this exact bottom-rows text. If it no longer does, the fixture has
    # drifted out of the false-park class and the negative control is vacuous.
    _bot=$(_ol_bottom_rows "$quoted_fixture")
    if grep -qE "$_OL_DEV_HEADLINE" <<<"$_bot" && grep -qE 'resets[[:space:]]+[^[:space:]]' <<<"$_bot"; then
        printf '  PASS: old two-grep detector WOULD have parked this (fixture is a true differential)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: old two-grep detector would not have parked this — negative control is vacuous\n' >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

echo
echo "=== dead-claude liveness gate ==="
# Reproduces the original bug: a pane whose inner `claude` REPL has
# exited but whose last-rendered bytes still match an alive-state
# regex (autosuggest, busy-spinner, idle-empty input row, bright
# user-typed text). With tmux's `remain-on-exit on`, those bytes
# linger forever; a regex-only classifier returns alive every poll
# and the watcher's dead-pane → cleanup-policy → restart path never
# fires. The fix hoists `_pane_has_live_claude` to the very top of
# the classifier, gating absent on process state regardless of
# rendered bytes or in-flight heartbeat. We exercise it via the
# `--pane-pid` test surface: pass a known-dead pid alongside an
# alive-looking fixture and assert state=absent.
DEAD_PID=999999
while kill -0 "$DEAD_PID" 2>/dev/null; do
    DEAD_PID=$(( DEAD_PID + 1 ))
done

assert_dead_pid_absent() {
    local fixture="$1" label="$2"; shift 2
    local extra=("$@")
    local out got
    out=$("$HELPER" --fixture "$fixture" --window 9 --name testwin --active 0 \
                    --pane-pid "$DEAD_PID" "${extra[@]}" 2>&1) || {
        printf '  FAIL: %s — helper exited nonzero: %s\n' "$label" "$out" >&2
        FAIL=$(( FAIL + 1 ))
        return
    }
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "absent" ]]; then
        printf '  PASS: %-58s state=%s\n' "$label" "$got"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %-58s got=%s want=absent (full: %s)\n' \
            "$label" "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# The pane content for each fixture would classify as alive without
# the gate; pairing each with a dead pid must produce absent.
assert_dead_pid_absent "$FIX_DIR/autosuggest-merge-win3.ansi"  "autosuggest bytes + dead pid → absent"
assert_dead_pid_absent "$FIX_DIR/busy-encode-win5.ansi"        "busy spinner + dead pid → absent"
assert_dead_pid_absent "$FIX_DIR/idle-empty-synthetic.ansi"    "idle empty input + dead pid → absent"
assert_dead_pid_absent "$FIX_DIR/user-typing-synthetic.ansi"   "user-typed bright text + dead pid → absent"
assert_dead_pid_absent "$FIX_DIR/busy-mid-render-no-chevron-synthetic.ansi" "busy mid-render + dead pid → absent"

# Process check supersedes a fresh heartbeat — heartbeat is a hint,
# pid liveness is ground truth. Without this guarantee, a worker that
# crashed within the heartbeat staleness window (default 30 s) would
# stay classified as busy until the heartbeat went stale.
hb_file="$hb_tmp/test.json"
printf '{"state":"busy","last_activity":%s,"window":"test"}\n' "$NOW" > "$hb_file"
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name test --active 0 \
                --heartbeat-file "$hb_file" --now "$NOW" \
                --pane-pid "$DEAD_PID" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "absent" ]]; then
    printf '  PASS: fresh busy heartbeat + dead pid → absent (process > heartbeat)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: fresh heartbeat + dead pid — got=%s want=absent (full: %s)\n' \
        "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Live, non-claude pid (sleep) must also classify as absent — the
# gate is "live claude descendant", not "live anything". A sleep
# child has no claude in its tree but is unambiguously alive.
#
# Grace pinned to 0 (your-org/nexus-code#777). This pid is forked on the line
# above, so at the default grace it is inside the boot window and `unknown` is
# the correct answer — a seconds-old process with nothing under it is exactly
# what a spawn looks like before its launcher is forked. The property this
# assertion was written for is the DESCENDANT rule, so take the boot window out
# of the picture and let it test only that.
sleep 60 &
SLEEP_PID=$!
out=$(NEXUS_PANE_BOOT_GRACE_SECONDS=0 "$HELPER" --fixture "$FIX_DIR/autosuggest-merge-win3.ansi" \
                --window 9 --name testwin --active 0 \
                --pane-pid "$SLEEP_PID" 2>&1)
kill "$SLEEP_PID" 2>/dev/null
wait "$SLEEP_PID" 2>/dev/null
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "absent" ]]; then
    printf '  PASS: alive sleep pid (no claude descendant) → absent\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: alive non-claude pid — got=%s want=absent (full: %s)\n' \
        "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# No --pane-pid: gate is bypassed (fixture mode default), classifier
# falls through to renderer matching. Guards against accidentally
# making the gate fire on every fixture-mode invocation.
out=$("$HELPER" --fixture "$FIX_DIR/autosuggest-merge-win3.ansi" \
                --window 9 --name testwin --active 0 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "autosuggest-only" ]]; then
    printf '  PASS: fixture mode without --pane-pid still classifies from renderer\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: fixture mode without --pane-pid — got=%s want=autosuggest-only (full: %s)\n' \
        "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== content_hash emission + absent precedence (#205 / PR 270) ==="
# The transcript-region fingerprint must (a) ride every renderer-path
# emit, (b) neutralise digit-only churn (timer/token ticks), (c) stay
# cheap and safe on a pane with NO `❯<NBSP>` row, and (d) never delay
# or displace the dead-pane `absent` verdict — the liveness gate runs
# before any capture, so a gate-emitted `absent` carries no hash.
ch_tmp=$(mktemp -d)
trap 'rm -rf "$hb_tmp" "$ch_tmp"' EXIT
NB=$'\xc2\xa0'
ESCB=$'\x1b'
# Base: two transcript lines, an idle banner with digits, an idle
# empty-cursor input row.
printf 'Routine transcript line one\n\xe2\x9c\xbb Brewed for 34m 12s\n\xe2\x9d\xaf%s%s[7m %s[0m\n' \
    "$NB" "$ESCB" "$ESCB" > "$ch_tmp/base.ansi"
# Digits-only delta: same shape, only the timer numbers moved.
printf 'Routine transcript line one\n\xe2\x9c\xbb Brewed for 51m 48s\n\xe2\x9d\xaf%s%s[7m %s[0m\n' \
    "$NB" "$ESCB" "$ESCB" > "$ch_tmp/digits.ansi"
# Textual delta: the transcript itself grew.
printf 'Routine transcript line one plus fresh prose\n\xe2\x9c\xbb Brewed for 34m 12s\n\xe2\x9d\xaf%s%s[7m %s[0m\n' \
    "$NB" "$ESCB" "$ESCB" > "$ch_tmp/text.ansi"
# Chevron-less: transcript only — _content_hash digests the whole capture.
printf 'just some plain output\nno chevron anywhere here\n' > "$ch_tmp/nochevron.ansi"

ch_field() { sed -n 's/.*content_hash=\([0-9]*\).*/\1/p' <<<"$1"; }

out_base=$("$HELPER" --fixture "$ch_tmp/base.ansi" --window 9 --name chw --active 0)
out_base2=$("$HELPER" --fixture "$ch_tmp/base.ansi" --window 9 --name chw --active 0)
out_digits=$("$HELPER" --fixture "$ch_tmp/digits.ansi" --window 9 --name chw --active 0)
out_text=$("$HELPER" --fixture "$ch_tmp/text.ansi" --window 9 --name chw --active 0)
h_base=$(ch_field "$out_base"); h_base2=$(ch_field "$out_base2")
h_digits=$(ch_field "$out_digits"); h_text=$(ch_field "$out_text")

if grep -q 'state=idle' <<<"$out_base" && [[ -n "$h_base" ]]; then
    printf '  PASS: renderer-path idle emit carries content_hash\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: idle emit missing content_hash (got: %s)\n' "$out_base" >&2; FAIL=$(( FAIL + 1 ))
fi
if [[ -n "$h_base" && "$h_base" == "$h_base2" ]]; then
    printf '  PASS: content_hash is stable across invocations\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: content_hash unstable (%s vs %s)\n' "$h_base" "$h_base2" >&2; FAIL=$(( FAIL + 1 ))
fi
if [[ -n "$h_base" && "$h_base" == "$h_digits" ]]; then
    printf '  PASS: digit-only delta (timer tick) leaves content_hash unchanged\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: digit-only delta moved the hash (%s vs %s)\n' "$h_base" "$h_digits" >&2; FAIL=$(( FAIL + 1 ))
fi
if [[ -n "$h_text" && "$h_base" != "$h_text" ]]; then
    printf '  PASS: textual transcript delta moves content_hash\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: textual delta did not move the hash (%s vs %s)\n' "$h_base" "$h_text" >&2; FAIL=$(( FAIL + 1 ))
fi

# --- fullscreen composer-nudge churn (your-org/nexus-code#573) -------------
# Under `tui: fullscreen` the input box is pinned to the bottom of the
# alternate screen and the gap above it is padded with blanks; into that gap
# Claude Code flashes a RIGHT-JUSTIFIED contextual nudge (`● <tip> · /<cmd>`)
# on its own timer. It sits ABOVE the `❯<NBSP>` row (so inside the hashed
# region) and is non-numeric (so the digit-strip missed it), which churned an
# idle pane's hash and pinned windows open. The fix keys on RIGHT-JUSTIFICATION
# (a LARGE leading-space run, ≥32): a `●` pushed to the right edge is chrome
# and is stripped; a `●` at column 0 OR any small indent (a code-fence line, a
# pasted TUI capture) is real content and must still move the hash — this is
# the over-strip guard the skeptic (req-001) demanded on the unrecoverable
# axis. Shapes mirror the real fullscreen capture measured via monitor/cc-harness
# on tmux 3.4: a `────` box border, a left-aligned `●` response, and the
# right-justified `● … · /effort` nudge ~64–103 columns in.
DASH=$'\xe2\x94\x80'; BUL=$'\xe2\x97\x8f'; MDOT=$'\xc2\xb7'
GAP=$(printf '%64s' '')                          # 64-space right-align padding
# A: nudge PRESENT in the gap (right-justified, 64 leading spaces).
printf 'Routine transcript line one\n%s Assistant answered the question here\n%s%s tip of the day %s /effort\n%s%s%s%s\n\xe2\x9d\xaf%s%s[7m %s[0m\n' \
    "$BUL" "$GAP" "$BUL" "$MDOT" "$DASH" "$DASH" "$DASH" "$DASH" \
    "$NB" "$ESCB" "$ESCB" > "$ch_tmp/fs_nudge.ansi"
# B: SAME pane, nudge GONE (blinked out) — only blank padding in the gap.
printf 'Routine transcript line one\n%s Assistant answered the question here\n%s\n%s%s%s%s\n\xe2\x9d\xaf%s%s[7m %s[0m\n' \
    "$BUL" "$GAP" "$DASH" "$DASH" "$DASH" "$DASH" \
    "$NB" "$ESCB" "$ESCB" > "$ch_tmp/fs_nonudge.ansi"
# C: a NEW left-aligned `●` assistant response arrived (genuine change) — the
# nudge strip must NOT swallow this; the hash must move relative to B.
printf 'Routine transcript line one\n%s Assistant answered the question here\n%s A second real assistant response\n%s\n%s%s%s%s\n\xe2\x9d\xaf%s%s[7m %s[0m\n' \
    "$BUL" "$BUL" "$GAP" "$DASH" "$DASH" "$DASH" "$DASH" \
    "$NB" "$ESCB" "$ESCB" > "$ch_tmp/fs_response.ansi"
# D (skeptic req-001): a real transcript line whose first glyph is a `●` at a
# SMALL indent — a `●` inside a fenced code block, a pasted TUI capture. The
# fix must NOT eat it; the hash must move relative to B. If the strip matched a
# `●` at ANY indent (the pre-req-001 code), this would collide with B and fail.
printf 'Routine transcript line one\n%s Assistant answered the question here\n  %s indented literal dot inside a fence\n%s\n%s%s%s%s\n\xe2\x9d\xaf%s%s[7m %s[0m\n' \
    "$BUL" "$BUL" "$GAP" "$DASH" "$DASH" "$DASH" "$DASH" \
    "$NB" "$ESCB" "$ESCB" > "$ch_tmp/fs_indent.ansi"

out_fsn=$("$HELPER" --fixture "$ch_tmp/fs_nudge.ansi"    --window 9 --name chw --active 0)
out_fs0=$("$HELPER" --fixture "$ch_tmp/fs_nonudge.ansi"  --window 9 --name chw --active 0)
out_fsr=$("$HELPER" --fixture "$ch_tmp/fs_response.ansi" --window 9 --name chw --active 0)
out_fsi=$("$HELPER" --fixture "$ch_tmp/fs_indent.ansi"   --window 9 --name chw --active 0)
h_fsn=$(ch_field "$out_fsn"); h_fs0=$(ch_field "$out_fs0")
h_fsr=$(ch_field "$out_fsr"); h_fsi=$(ch_field "$out_fsi")

# POSITIVE: the blinking right-justified nudge is invisible to the hash — the
# idle pane reads STABLE whether the nudge is drawn or not.
if [[ -n "$h_fsn" && "$h_fsn" == "$h_fs0" ]]; then
    printf '  PASS: fullscreen composer nudge stripped — idle hash stable across blink\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: fullscreen nudge churned the hash (present=%s absent=%s)\n' "$h_fsn" "$h_fs0" >&2; FAIL=$(( FAIL + 1 ))
fi
# NEGATIVE (guards over-stripping): a left-aligned `●` response is real
# content and MUST still move the hash. If the strip were alignment-blind
# (matching a bare `●`) this would collide with B and the assertion fails.
if [[ -n "$h_fsr" && "$h_fsr" != "$h_fs0" ]]; then
    printf '  PASS: left-aligned assistant response still moves the hash (no over-strip)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: real response did not move the hash — nudge strip over-reached (%s vs %s)\n' "$h_fsr" "$h_fs0" >&2; FAIL=$(( FAIL + 1 ))
fi
# NEGATIVE / skeptic req-001: a SMALL-indent `●` (code-fence content, pasted
# capture) is real content and MUST still move the hash — the strip's
# right-justification threshold must spare it, on the unrecoverable axis.
if [[ -n "$h_fsi" && "$h_fsi" != "$h_fs0" ]]; then
    printf '  PASS: small-indent ● content still moves the hash (right-justification threshold spares it)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: small-indent ● content was eaten by the nudge strip (%s vs %s)\n' "$h_fsi" "$h_fs0" >&2; FAIL=$(( FAIL + 1 ))
fi

# Chevron-less pane: classifies absent via the renderer fallback
# (no input row, no spinner, no pid supplied) and must still emit a
# whole-capture hash — proving _content_hash neither hangs nor
# misclassifies when the `❯<NBSP>` anchor is missing.
out_noc=$("$HELPER" --fixture "$ch_tmp/nochevron.ansi" --window 9 --name chw --active 0)
h_noc=$(ch_field "$out_noc")
if grep -q 'state=absent' <<<"$out_noc" && [[ -n "$h_noc" ]]; then
    printf '  PASS: chevron-less pane → renderer absent + whole-capture hash\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: chevron-less pane (got: %s)\n' "$out_noc" >&2; FAIL=$(( FAIL + 1 ))
fi

# Dead pid + alive-looking bytes: the liveness gate decides `absent`
# BEFORE any capture or fingerprint work, so the emit must carry NO
# content_hash. Guards the PR 270 ordering: fingerprinting must never
# sit ahead of (or delay) the dead-pane verdict.
out_dead=$("$HELPER" --fixture "$ch_tmp/base.ansi" --window 9 --name chw --active 0 \
                     --pane-pid "$DEAD_PID")
if grep -q 'state=absent' <<<"$out_dead" && ! grep -q 'content_hash=' <<<"$out_dead"; then
    printf '  PASS: dead pid → absent decided ahead of fingerprint (no content_hash)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: dead-pid emit wrong shape (got: %s)\n' "$out_dead" >&2; FAIL=$(( FAIL + 1 ))
fi

# Zombie claude: an exited-but-unreaped `claude` in the pane tree is
# NOT alive — the gate must read it as dead and emit absent. This is
# the unit-level stand-in for the realmodel kill scenario: after the
# harness TERMs the pane tree, any window where the corpse lingers
# (slow reap, slow teardown) must still classify absent within the
# poll budget. Requires python3 (Popen-without-wait makes the zombie).
if command -v python3 >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' > "$ch_tmp/claude"
    chmod +x "$ch_tmp/claude"
    python3 -c 'import subprocess,sys,time; subprocess.Popen([sys.argv[1]]); time.sleep(30)' \
        "$ch_tmp/claude" &
    ZPARENT=$!
    # Give the child a beat to exec, exit, and become a zombie.
    sleep 0.5
    # Grace pinned to 0 (your-org/nexus-code#777): $ZPARENT is half a second
    # old, so the default grace legitimately answers `unknown`. What is under
    # test here is that a ZOMBIE claude does not count as live — a property of
    # the tree walk, not of the boot window.
    out_z=$(NEXUS_PANE_BOOT_GRACE_SECONDS=0 "$HELPER" --fixture "$ch_tmp/base.ansi" --window 9 --name chw --active 0 \
                      --pane-pid "$ZPARENT")
    kill "$ZPARENT" 2>/dev/null; wait "$ZPARENT" 2>/dev/null
    if grep -q 'state=absent' <<<"$out_z"; then
        printf '  PASS: zombie claude in pane tree → absent (corpse is not alive)\n'; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: zombie claude read as live (got: %s)\n' "$out_z" >&2; FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  SKIP: zombie-claude case (python3 unavailable)\n'
fi

echo
echo "=== async-signal idle refinement (issue #183) ==="
# Refinement applies when the renderer (or heartbeat) would have
# emitted `idle`. The four refined classes:
#   working-background  footer Monitor token OR a live background shell (#1374: never the heartbeat)
#   working-self-paced  scheduled_wakeup_at > now
#   idle-orphan-async   external_waits != [] AND no monitor/wakeup
#   idle                none of the above
# Heartbeat is authoritative when fresh; pane-footer fills in the
# monitor/bg counts when heartbeat is missing or stale.
async_tmp=$(mktemp -d)
trap 'rm -rf "$hb_tmp" "$ch_tmp" "$async_tmp"' EXIT
ASYNC_NOW=2000000000
async_hb="$async_tmp/async.json"

write_async_hb() {
    # Args: <state> <age> <ignored> <ignored> <scheduled_wakeup_at|-> <external_waits_json>
    # Positions 3 and 4 used to plant `monitor_handles` / `background_bash_count`
    # — fields NO production writer has ever emitted (your-org/nexus-code#1374),
    # so a fixture carrying them asserted a path production could not take.
    # They are accepted and ignored so the call sites read unchanged; the
    # heartbeat written here is the WRITER's schema, nothing more.
    local state="$1" age="$2" swa="$5" waits="$6"
    local last_activity=$(( ASYNC_NOW - age ))
    if [[ "$swa" == "-" ]]; then
        jq -nc \
            --arg s "$state" --argjson la "$last_activity" --arg w test \
            --argjson ew "$waits" \
            '{state:$s, last_activity:$la, window:$w, external_waits:$ew, dismissed_waits:[]}' \
            > "$async_hb"
    else
        jq -nc \
            --arg s "$state" --argjson la "$last_activity" --arg w test \
            --argjson swa "$swa" --argjson ew "$waits" \
            '{state:$s, last_activity:$la, window:$w, scheduled_wakeup_at:$swa, external_waits:$ew, dismissed_waits:[]}' \
            > "$async_hb"
    fi
}
# The two handle signals are driven by their REAL sources (#1374): a Monitor
# handle by the pane footer's `· 1 monitor ·` token, a background shell by
# the process-tree override.
mon_footer_fixture="$FIX_DIR/working-background-monitor-synthetic.ansi"

assert_async_state() {
    local label="$1" want_state="$2" want_extra="$3"; shift 3
    local out got_state got_extra
    out=$("$HELPER" --fixture "$idle_fixture" \
                    --window 9 --name test --active 0 \
                    --heartbeat-file "$async_hb" \
                    --now "$ASYNC_NOW" \
                    "$@" 2>&1) || {
        printf '  FAIL: %s — helper rc nonzero: %s\n' "$label" "$out" >&2
        FAIL=$(( FAIL + 1 ))
        return
    }
    got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got_state" == "$want_state" ]]; then
        printf '  PASS: %-55s state=%s\n' "$label" "$got_state"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %-55s got=%s want=%s (full: %s)\n' \
            "$label" "$got_state" "$want_state" "$out" >&2
        FAIL=$(( FAIL + 1 ))
        return
    fi
    if [[ -n "$want_extra" ]]; then
        if grep -qF "$want_extra" <<<"$out"; then
            printf '  PASS: %-55s extra=%s\n' "$label (extra)" "$want_extra"
            PASS=$(( PASS + 1 ))
        else
            printf '  FAIL: %-55s missing extra: %s (full: %s)\n' \
                "$label (extra)" "$want_extra" "$out" >&2
            FAIL=$(( FAIL + 1 ))
        fi
    fi
}

# (1) working-background: monitor handle live — in the FOOTER, its only source.
write_async_hb idle_prompt 5 0 0 - '[]'
assert_async_state "footer '· 1 monitor ·' → working-background" \
    working-background "" --fixture "$mon_footer_fixture"

# (1b) working-background: background bash live — in the PROCESS TREE.
write_async_hb idle_prompt 5 0 0 - '[]'
assert_async_state "process tree bg_shells=2 → working-background" \
    working-background "" --bg-shells 2

# (1c) #1374: a heartbeat that PLANTS the never-written fields is NOT a signal.
#      Production could never take this path; a fixture that did was asserting
#      a defence that did not exist.
jq -nc --argjson la "$(( ASYNC_NOW - 5 ))" \
    '{state:"idle_prompt", last_activity:$la, window:"test", monitor_handles:1, background_bash_count:2, external_waits:[], dismissed_waits:[]}' > "$async_hb"
assert_async_state "#1374 planted monitor_handles/background_bash_count → plain idle (no such arm)" \
    idle ""

# (2) working-self-paced: scheduled_wakeup_at > now.
write_async_hb idle_prompt 5 0 0 "$(( ASYNC_NOW + 300 ))" '[]'
assert_async_state "scheduled_wakeup_at>now → working-self-paced" \
    working-self-paced ""

# (2b) past wakeup → does NOT cause working-self-paced.
write_async_hb idle_prompt 5 0 0 "$(( ASYNC_NOW - 60 ))" '[]'
assert_async_state "scheduled_wakeup_at<now → plain idle" \
    idle ""

# (3) idle-orphan-async: external_waits non-empty, no resume signal.
write_async_hb idle_prompt 5 0 0 - \
    '[{"kind":"slurm","id":"52527284_4","desc":"BL"}]'
assert_async_state "external_waits non-empty → idle-orphan-async" \
    idle-orphan-async "orphan_kinds=slurm:52527284_4"

# (3b) multiple external_waits surface as csv summary.
write_async_hb idle_prompt 5 0 0 - \
    '[{"kind":"slurm","id":"1","desc":""},{"kind":"ci","id":"abc/runs/9","desc":""}]'
assert_async_state "multi-waits → orphan_kinds csv" \
    idle-orphan-async "orphan_kinds=slurm:1,ci:abc/runs/9"

# (3c) external_waits empty array → plain idle.
write_async_hb idle_prompt 5 0 0 - '[]'
assert_async_state "empty external_waits → plain idle" \
    idle ""

# (4) Priority: monitor handle (footer) beats external_waits.
write_async_hb idle_prompt 5 0 0 - \
    '[{"kind":"slurm","id":"99999","desc":""}]'
assert_async_state "monitor + waits → working-background wins" \
    working-background "" --fixture "$mon_footer_fixture"

# (4b) scheduled_wakeup beats external_waits.
write_async_hb idle_prompt 5 0 0 "$(( ASYNC_NOW + 60 ))" \
    '[{"kind":"slurm","id":"77777","desc":""}]'
assert_async_state "wakeup + waits → working-self-paced wins" \
    working-self-paced ""

# (5) THE TWO HORIZONS ARE NOT ONE HORIZON (your-org/nexus-code#1220).
#
# This case used to be a single assertion: heartbeat 3600 s old, an
# `external_waits` array present, expect `idle` — i.e. it PINNED the very
# behaviour #1220 reports as the defect, that a declared wait goes invisible
# once the worker falls quiet. It passed for eighteen months while ten real
# waits sat hidden for 18.9 h on a live window. Rewritten to assert the
# property rather than the old number, in BOTH directions.
#
# The distinction the code now makes: the 60 s horizon expires signals that
# GRANT AN EXEMPTION (`monitor_handles`, `background_bash_count`,
# `scheduled_wakeup_at` -> `working-background` / `working-self-paced`, both
# in `_BK_ACTIVE_STATES`, both refusing a kill). `external_waits` grants no
# exemption — `idle-orphan-async` is in `_BK_KILL_OK_STATES` next to plain
# `idle` — so expiring it deletes a declaration instead of withdrawing a
# privilege, and gets its own, far longer horizon.

# (5a) The EXEMPTION-granting signals still expire at 60 s. This is the half
#      the short horizon is actually for, and it must not regress.
write_async_hb idle_prompt 5 3 0 - '[]'
jq -c '.last_activity = (.last_activity - 3600)' "$async_hb" \
    > "$async_hb.tmp" && mv "$async_hb.tmp" "$async_hb"
assert_async_state "5a stale monitor handles STILL expire → idle" \
    idle ""

# (5b) A declared wait SURVIVES the same 3600 s quiet. A worker blocked on an
#      external wait is quiet BECAUSE it is blocked, so quiet cannot be the
#      evidence that no wait is outstanding.
write_async_hb idle_prompt 5 0 0 - \
    '[{"kind":"slurm","id":"x","desc":""}]'
jq -c '.last_activity = (.last_activity - 3600)' "$async_hb" \
    > "$async_hb.tmp" && mv "$async_hb.tmp" "$async_hb"
assert_async_state "5b declared wait SURVIVES 3600s quiet → idle-orphan-async" \
    idle-orphan-async "orphan_kinds=slurm:x"

# (5c) …and it is a HORIZON, not the absence of one. Past 48 h an abandoned
#      heartbeat stops declaring. Without this arm the fix would be
#      indistinguishable from removing the check altogether.
write_async_hb idle_prompt 5 0 0 - \
    '[{"kind":"slurm","id":"z","desc":""}]'
jq -c '.last_activity = (.last_activity - 200000)' "$async_hb" \
    > "$async_hb.tmp" && mv "$async_hb.tmp" "$async_hb"
assert_async_state "5c wait past the 48h horizon expires → idle" \
    idle ""

# (6) Custom async-staleness lets a row in.
write_async_hb idle_prompt 5 0 0 - \
    '[{"kind":"slurm","id":"y","desc":""}]'
# Make it 90 s old, then permit via --heartbeat-async-staleness 120.
jq -c '.last_activity = (.last_activity - 85)' "$async_hb" \
    > "$async_hb.tmp" && mv "$async_hb.tmp" "$async_hb"
# Heartbeat-state staleness for `idle_prompt` (last_turn_end-anchored)
# is 1800 s by default; well within the 85-s age. So the heartbeat-
# fast-path still emits `idle`. Then refinement triggers because the
# async-staleness override permits it.
assert_async_state "--heartbeat-async-staleness 120 allows 85s-old waits" \
    idle-orphan-async "orphan_kinds=slurm:y" \
    --heartbeat-async-staleness 120

# (7) Pane-footer fallback: no heartbeat, but fixture shows `1 monitor`.
foot_mon_fixture="$FIX_DIR/working-background-monitor-synthetic.ansi"
if [[ -f "$foot_mon_fixture" ]]; then
    out=$("$HELPER" --fixture "$foot_mon_fixture" \
                    --window 9 --name ftest --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: no heartbeat + footer "1 monitor" → working-background\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: footer fallback monitor — got=%s want=working-background\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

foot_bg_fixture="$FIX_DIR/working-background-bgbash-synthetic.ansi"
if [[ -f "$foot_bg_fixture" ]]; then
    out=$("$HELPER" --fixture "$foot_bg_fixture" \
                    --window 9 --name ftest --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: no heartbeat + footer "N background bash" → working-background\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: footer fallback bg — got=%s want=working-background\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# (8) Footer count is preferred over heartbeat zeros (heartbeat hook
#     can't introspect claude's handle list, so 0 there is "no signal"
#     not "definitely zero"). If the heartbeat lacks a wait and the
#     footer carries monitor, we still pick working-background.
if [[ -f "$foot_mon_fixture" ]]; then
    write_async_hb idle_prompt 5 0 0 - '[]'
    out=$("$HELPER" --fixture "$foot_mon_fixture" \
                    --window 9 --name ftest --active 0 \
                    --heartbeat-file "$async_hb" \
                    --now "$ASYNC_NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: heartbeat zeros + footer monitor → working-background\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: heartbeat+footer OR — got=%s want=working-background\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# (9) external_waits has NO renderer fallback — pane bytes can't
#     declare a slurm wait. A fixture without footer signals and no
#     heartbeat must classify as plain idle.
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name ntest --active 0 \
                --heartbeat-file "$async_tmp/missing.json" \
                --now "$ASYNC_NOW" 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "idle" ]]; then
    printf '  PASS: no heartbeat + no footer signals → idle (not orphan-async)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: no-signal — got=%s want=idle\n' "$got" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== real-footer shell phrasing + bg_cpu scoping (your-org/nexus-code#445) ==="
# The pre-#445 regex looked for the word "background" and never matched
# the real Claude Code v2.1.204 status line `· N shell[s], N monitor ·`,
# so a worker idling between turns with a live background shell was
# false-classified `idle` → spurious idle-without-wrap-up nag.

# (10) Real status-line `1 shell, 1 monitor` (no spinner "still
#      running") → working-background. This is the exact form the old
#      regex missed. Footer fallback (no heartbeat).
real_foot="$FIX_DIR/working-background-shell-realfooter.ansi"
if [[ -f "$real_foot" ]]; then
    out=$("$HELPER" --fixture "$real_foot" \
                    --window 9 --name paperbench --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" --bg-cpu 1200 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: real "1 shell, 1 monitor" footer → working-background\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: real-footer shell — got=%s want=working-background (full: %s)\n' "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # (10b) shell-driven working-background CARRIES bg_cpu (grace-capped).
    if grep -qF 'bg_cpu=1200' <<<"$out"; then
        printf '  PASS: shell-driven working-background carries bg_cpu\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: shell-driven missing bg_cpu (full: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# (10c) Monitor-handle working-background carries NO bg_cpu (it is
#       self-waking and must never be subjected to the shell
#       orphan-grace). Footer `· 1 monitor ·`, no shell.
write_async_hb idle_prompt 5 0 0 - '[]'
out=$("$HELPER" --fixture "$mon_footer_fixture" \
                --window 9 --name montest --active 0 \
                --heartbeat-file "$async_hb" \
                --now "$ASYNC_NOW" --bg-cpu 9999 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "working-background" ]] && ! grep -qF 'bg_cpu=' <<<"$out"; then
    printf '  PASS: monitor-handle working-background omits bg_cpu\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: monitor-handle bg_cpu scoping — got=%s (full: %s)\n' "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# (10d) shell-count from the process tree (bg_shells=3) → shell
#       driver → bg_cpu present.
write_async_hb idle_prompt 5 0 0 - '[]'
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name bgtest --active 0 \
                --heartbeat-file "$async_hb" \
                --now "$ASYNC_NOW" --bg-shells 3 --bg-cpu 555 2>&1)
if grep -qF 'state=working-background' <<<"$out" && grep -qF 'bg_cpu=555' <<<"$out"; then
    printf '  PASS: process-tree shell count → shell-driven bg_cpu\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: heartbeat bg-count bg_cpu — (full: %s)\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== OSC 8 hyperlinks in the footer must not blind the handle-count parse ==="
# _strip_ansi used to strip CSI only, so an OSC 8 hyperlink
# (ESC ] 8 ; ; <url> ESC \ <anchor> ESC ] 8 ; ; ESC \) survived into the
# plain text _footer_handle_counts parses — right on the ` · N shell[s] · `
# boundary its regex anchors on. Claude Code renders clickable badges this
# way. Both cases below use the FOOTER FALLBACK deliberately (no heartbeat,
# no --bg-shells), because the footer parse is the surface under test.

# (10e) POSITIVE: the handle count itself is inside a hyperlink. Under the
#       old CSI-only strip the `·`→digit boundary is broken by the raw
#       escape bytes and the count is missed → idle. It must read
#       working-background.
osc_foot="$FIX_DIR/working-background-osc8-prbadge-synthetic.ansi"
if [[ -f "$osc_foot" ]]; then
    out=$("$HELPER" --fixture "$osc_foot" \
                    --window 9 --name osc8 --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" --bg-cpu 777 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: OSC 8-wrapped "2 shells" footer → working-background\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: OSC 8 footer count missed — got=%s want=working-background (full: %s)\n' "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  FAIL: missing fixture %s\n' "$osc_foot" >&2
    FAIL=$(( FAIL + 1 ))
fi

# (10f) NEGATIVE CONTROL: the same PR-badge hyperlink, but NO handle count
#       anywhere. Stripping OSC must not manufacture a count out of the
#       URL's digits — without this control, (10e) could "pass" by making
#       _footer_handle_counts fire on any pane containing a hyperlink.
osc_idle="$FIX_DIR/idle-osc8-prbadge-nocounts-synthetic.ansi"
if [[ -f "$osc_idle" ]]; then
    out=$("$HELPER" --fixture "$osc_idle" \
                    --window 9 --name osc8n --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" --bg-cpu 777 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "idle" ]]; then
        printf '  PASS: PR-badge hyperlink with no count → still idle (no phantom handle)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: OSC 8 negative control — got=%s want=idle (full: %s)\n' "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  FAIL: missing fixture %s\n' "$osc_idle" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== process-tree as the authoritative background-shell signal (your-org/nexus-code#455) ==="
# The status-line `N shell` footer is presentation: a user can customise
# the status bar, it changes across CC versions, and a regex can match
# unrelated pane text. #455 makes the kernel PROCESS TREE (claude's live
# background-shell child subtrees) the primary + authoritative signal,
# demoting the footer regex to a fallback for when /proc can't be read.
# `--bg-shells N` injects a RELIABLE process-tree reading (count=N) so the
# fixtures can exercise the authoritative path.

# (11a) UP override — a live background shell the status bar does NOT show
#       (customised/changed footer). Clean idle fixture (no footer shell
#       token, no heartbeat) + a reliable process-tree count of 2 →
#       working-background. The footer regex would have missed this
#       (the #445-class false-idle, now caught by process truth).
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name pt-up --active 0 \
                --heartbeat-file "$async_tmp/missing.json" \
                --now "$ASYNC_NOW" --bg-shells 2 --bg-cpu 4242 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "working-background" ]] && grep -qF 'bg_cpu=4242' <<<"$out"; then
    printf '  PASS: process-tree count>0 with silent footer → working-background + bg_cpu\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: process-tree UP override — got=%s (full: %s)\n' "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# (11b) DOWN override — a spurious footer `· 2 shells ·` (coincidental
#       text / customised status bar) with NO live background shell.
#       A reliable process-tree count of 0 must OVERRIDE the footer down
#       to `idle`. This is the false-positive the operator flagged:
#       "the regex may match other output in the window".
spurious_foot="$FIX_DIR/working-background-spurious-shell-footer-synthetic.ansi"
if [[ -f "$spurious_foot" ]]; then
    # (11b-i) Fallback path (no reliable tree reading): the footer regex
    #         still fires → working-background. Confirms the fragile
    #         fallback is intact for /proc-restricted environments AND
    #         demonstrates the fragility the process tree corrects.
    out=$("$HELPER" --fixture "$spurious_foot" \
                    --window 9 --name pt-fallback --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "working-background" ]]; then
        printf '  PASS: spurious footer, no tree reading → working-background (fallback intact)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: footer fallback — got=%s (full: %s)\n' "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # (11b-ii) Authoritative path (reliable tree count=0): overrides the
    #          spurious footer down to idle.
    out=$("$HELPER" --fixture "$spurious_foot" \
                    --window 9 --name pt-down --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" --bg-shells 0 2>&1)
    got=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got" == "idle" ]]; then
        printf '  PASS: reliable process-tree count=0 overrides spurious footer → idle\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: process-tree DOWN override — got=%s want=idle (full: %s)\n' "$got" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# (11c) Monitor is NOT visible to the process tree — a reliable tree
#       count of 0 must NOT suppress a live Monitor handle (footer
#       `· 1 monitor ·`). Still working-background, and (Monitor-driven)
#       carries NO bg_cpu.
write_async_hb idle_prompt 5 0 0 - '[]'
out=$("$HELPER" --fixture "$mon_footer_fixture" \
                --window 9 --name pt-mon --active 0 \
                --heartbeat-file "$async_hb" \
                --now "$ASYNC_NOW" --bg-shells 0 2>&1)
got=$(awk -F'[ =]' '{print $2}' <<<"$out")
if [[ "$got" == "working-background" ]] && ! grep -qF 'bg_cpu=' <<<"$out"; then
    printf '  PASS: tree count=0 does not suppress Monitor handle → working-background, no bg_cpu\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: Monitor-not-in-tree — got=%s (full: %s)\n' "$got" "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== bg_shells + bg_reliable emit fields (your-org/nexus-code#455 refine) ==="
# A shell-driven working-background line must ALSO carry bg_shells=<count>
# and bg_reliable=<0|1> so the watcher's idle probe can key its
# idle-with-children backoff + wrap-up-with-children inconsistency detector.

# (12a) Authoritative shell-driven reading → bg_shells=<count> bg_reliable=1.
out=$("$HELPER" --fixture "$idle_fixture" \
                --window 9 --name bgfields-rel --active 0 \
                --heartbeat-file "$async_tmp/missing.json" \
                --now "$ASYNC_NOW" --bg-shells 3 --bg-cpu 777 2>&1)
if grep -qF 'state=working-background' <<<"$out" \
   && grep -qF 'bg_shells=3' <<<"$out" \
   && grep -qF 'bg_reliable=1' <<<"$out" \
   && grep -qF 'bg_cpu=777' <<<"$out"; then
    printf '  PASS: authoritative shell-driven → bg_shells + bg_reliable=1 + bg_cpu\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: bg_shells/bg_reliable emit — (full: %s)\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# (12b) Fallback path (footer-driven, unreliable tree) → the shell-driven
#       line still carries bg_reliable=0 so the probe keeps legacy behaviour.
real_foot="$FIX_DIR/working-background-shell-realfooter.ansi"
if [[ -f "$real_foot" ]]; then
    out=$("$HELPER" --fixture "$real_foot" \
                    --window 9 --name bgfields-fallback --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" \
                    --now "$ASYNC_NOW" --bg-cpu 1200 2>&1)
    if grep -qF 'state=working-background' <<<"$out" \
       && grep -qF 'bg_reliable=0' <<<"$out"; then
        printf '  PASS: footer-fallback shell-driven → bg_reliable=0\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: footer-fallback bg_reliable — (full: %s)\n' "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# (12c) Monitor-handle working-background carries NEITHER bg_shells nor
#       bg_reliable (it is not shell-driven).
write_async_hb idle_prompt 5 0 0 - '[]'
out=$("$HELPER" --fixture "$mon_footer_fixture" \
                --window 9 --name bgfields-mon --active 0 \
                --heartbeat-file "$async_hb" \
                --now "$ASYNC_NOW" --bg-shells 0 2>&1)
if grep -qF 'state=working-background' <<<"$out" \
   && ! grep -qF 'bg_shells=' <<<"$out" \
   && ! grep -qF 'bg_reliable=' <<<"$out"; then
    printf '  PASS: Monitor-handle working-background omits bg_shells/bg_reliable\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: Monitor-handle bg-fields scoping — (full: %s)\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== bogus-index fail-loud (issue #140) ==="
# Real-tmux tests: a non-existent window index must emit a clear
# stderr error, exit 3, and produce no stdout (so a grep-style probe
# like `pane-state.sh <idx> | grep state=absent` cannot false-match).
# A valid index whose pane has no claude descendant must still emit
# `state=absent active=<x> window=<idx> name=<actual>` + exit 0 —
# the existing dead-claude semantics are preserved, only the
# bogus-index footgun is removed.
#
# Self-skip when tmux isn't on PATH (e.g. minimal contributor envs).
# CI installs tmux explicitly; the gate is for local dev convenience.
if command -v tmux >/dev/null 2>&1; then
    bogus_tmpdir=$(mktemp -d)
    bogus_sock="nexus-pane-state-140-$$-$RANDOM"
    bogus_session="ps140"
    # THE REAL BINARY, NOT `command -v tmux` (your-org/nexus-code#1105).
    # Under an agent, `command -v tmux` is monitor/tmuxwrap/tmux. Interpolating
    # it into the shim below puts the wrapper's own path in the shim's body;
    # tmuxwrap's gate-3 then classifies THE SHIM as a wrapper, skips it, and
    # resolves the real tmux WITH NO -L. $BASH_ENV re-fronts tmuxwrap ahead of
    # this fixture's PATH prepend in every child shell, so `pane-state.sh` ran
    # its query against the OPERATOR'S LIVE SERVER — where `ps140:0` does not
    # exist — and the two assertions below failed about the wrong server.
    # Measured: 196/2 for every agent in the sandbox, 198/0 outside it, with
    # $BASH_ENV the only discriminating variable. Invisible to CI, which does
    # not set it.
    . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_tmux-fixture.sh"
    bogus_tmux_bin=$(nx_real_tmux_bin) || {
        echo "SKIP: no real tmux BINARY on PATH (only wrappers) — cannot isolate this fixture" >&2
        bogus_tmux_bin=""
    }
    # BRACES (your-org/nexus-code#1115 skeptic F2). The belt above stops
    # tmuxwrap's gate-3 skipping this shim; braces make a pin lost to some
    # FUTURE force-front harmless rather than board-reaching. Without them this
    # fixture's servers live in /tmp/tmux-<uid>/ right beside the board's own
    # `default` socket. $TMUX outranks $TMUX_TMPDIR (#644), so the unset is not
    # optional. This is the only tmux server this suite creates (grepped: the
    # sole `-L` sites are this shim and cleanup_bogus), so scoping the change
    # here cannot perturb another fixture.
    export TMUX_TMPDIR="$bogus_tmpdir/tt"
    mkdir -p "$TMUX_TMPDIR"
    unset TMUX
    # nx_write_tmux_shim REFUSES a wrapper-built shim, so the construction that
    # caused #1105 cannot reappear here silently.
    nx_write_tmux_shim "$bogus_tmpdir" "$bogus_tmux_bin" "$bogus_sock" || {
        echo "ENV-FAIL: could not write the private-tmux shim" >&2
        exit 1
    }
    cleanup_bogus() {
        # Pin the socket EXPLICITLY (-L), never via the PATH shim. The shim's
        # creation above is unchecked and this same function `rm -rf`s the dir
        # holding it, so a shim-dependent teardown resolves to the real tmux
        # the moment either fails — and `$TMUX` (always set: every agent runs
        # in a pane) then beats any TMUX_TMPDIR, landing `kill-server` on the
        # operator's server and tearing down the whole sandbox.
        # your-org/nexus-code#644.
        "$bogus_tmux_bin" -L "$bogus_sock" kill-server 2>/dev/null || true
        rm -rf "$bogus_tmpdir"
    }
    trap cleanup_bogus EXIT

    # THE ALARM (your-org/nexus-code#1105, #1115 skeptic F2). Assert that the
    # pin actually survives into a FRESH `bash` — which is how this suite
    # invokes $HELPER, and is exactly where the pin was silently displaced
    # before. A subshell would NOT reproduce the condition: $BASH_ENV is
    # sourced at the start of a non-interactive shell, so only a new bash
    # re-fronts monitor/tmuxwrap ahead of this fixture's PATH.
    _ps_want_sock="$TMUX_TMPDIR/tmux-$(id -u)/$bogus_sock"
    if nx_assert_tmux_pinned "$bogus_tmpdir" "$_ps_want_sock" 2>/dev/null; then
        printf '  PASS: ISOLATION CONTROL — a child `bash` reaches the FIXTURE socket, not the board (#1105)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: ISOLATION CONTROL — $HELPER would query a DIFFERENT tmux server than this fixture (#1105); every assertion below would be about that server\n' >&2
        FAIL=$(( FAIL + 1 ))
    fi

    # Bring up an isolated tmux server. `-f` neutralises the operator's
    # personal tmux.conf so it can't perturb window names or base-index —
    # but `-f` alone does NOT pin `default-shell`, which tmux derives from
    # the invoking user. That omission is your-org/nexus-code#661.
    #
    # tmux runs `sleep 36000` THROUGH the pane shell, and shells differ in
    # whether they exec it or fork first:
    #
    #   bash          execs directly           → pane pid IS sleep, no children
    #   zsh 5.4.2     forks, then settles      → a live child for ~0.5s
    #   sh (dash)     forks and does NOT       → a live child indefinitely
    #                 settle under the
    #                 default-command form
    #
    # Since your-org/nexus-code#649 a live descendant with no claude is
    # `unknown`, not `absent` — correctly. So this fixture's verdict was a
    # function of the OPERATOR'S ambient $SHELL and of host load: bash
    # passed, this lab's zsh raced and failed under suite load, and CI's
    # shell reproduced neither. A green cell meant something different
    # from a green local run.
    #
    # NOT `th_tmux_fixture_conf` (the #555 guard) here, deliberately, and
    # this is the one place that deviates from it: it pins `sh`, which is
    # dash on this host, and dash under that config keeps a live child
    # INDEFINITELY — measured `unknown` at 0s, 0.5s and 2s. Applying the
    # generic guard would make this case permanently red rather than fix
    # it. The guard is right about the axis and wrong about the value for
    # a fixture that asserts on the pane's PROCESS TREE.
    #
    # Two independent defences, because the pin alone is a host
    # assumption:
    #   1. pin a shell that execs (bash), so no fork window exists
    #   2. WAIT for the pane to settle, so the assertion never depends on
    #      exec-vs-fork at all — this is the property the case actually
    #      needs, and it is what the old code silently assumed
    printf 'set -g base-index 0\nset -g pane-base-index 0\nset -g status off\n' \
        > "$bogus_tmpdir/tmux.conf"
    _ps661_shell=$(command -v bash 2>/dev/null) || _ps661_shell=""
    [[ -n "$_ps661_shell" ]] \
        && printf 'set -g default-shell %s\n' "$_ps661_shell" >> "$bogus_tmpdir/tmux.conf"
    PATH="$bogus_tmpdir:$PATH" tmux -f "$bogus_tmpdir/tmux.conf" new-session -d \
        -s "$bogus_session" -x 80 -y 24 'sleep 36000'

    # Resolve the first real window index — base-index may be 0 or 1
    # depending on the operator's tmux defaults. We took -f /dev/null
    # so it defaults to 0, but read it dynamically for robustness.
    valid_idx=$(PATH="$bogus_tmpdir:$PATH" tmux list-windows \
                  -t "$bogus_session" -F '#{window_index}' | head -1)

    # Pick a bogus index guaranteed to be outside the live set.
    bogus_idx=99999

    # Case 1: bogus index → stderr message, exit 3, no stdout.
    bogus_out_file=$(mktemp)
    bogus_err_file=$(mktemp)
    PATH="$bogus_tmpdir:$PATH" \
        bash "$HELPER" "${bogus_session}:${bogus_idx}" \
        >"$bogus_out_file" 2>"$bogus_err_file"
    bogus_rc=$?
    bogus_stdout=$(<"$bogus_out_file")
    bogus_stderr=$(<"$bogus_err_file")
    rm -f "$bogus_out_file" "$bogus_err_file"
    if (( bogus_rc == 3 )) \
       && [[ -z "$bogus_stdout" ]] \
       && [[ "$bogus_stderr" == *"no such tmux window: ${bogus_idx}"* ]]; then
        printf '  PASS: bogus index → exit 3, empty stdout, stderr names it\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: bogus index — rc=%s stdout=%q stderr=%q\n' \
            "$bogus_rc" "$bogus_stdout" "$bogus_stderr" >&2
        FAIL=$(( FAIL + 1 ))
    fi

    # Case 1b: grep-style probe must not see a positive `state=absent`
    # match for the bogus-index path. This is the canonical
    # orchestrator footgun pattern called out in the issue.
    grep_probe_out=$(PATH="$bogus_tmpdir:$PATH" \
        bash "$HELPER" "${bogus_session}:${bogus_idx}" 2>/dev/null \
        | grep -c 'state=absent' || true)
    if [[ "$grep_probe_out" == "0" ]]; then
        printf '  PASS: grep state=absent finds nothing for bogus index\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: grep state=absent saw %s matches for bogus index\n' \
            "$grep_probe_out" >&2
        FAIL=$(( FAIL + 1 ))
    fi

    # Case 2: valid window, SETTLED pane running sleep (no claude and
    # nothing else alive in its tree) → `state=absent` + populated name +
    # exit 0. The documented dead-claude path the bogus-index fix must not
    # regress.
    #
    # The settle wait is load-bearing, not defensive padding
    # (your-org/nexus-code#661). "A pane with no claude in its tree
    # reports absent" presupposes a pane that has finished BECOMING what
    # is being asserted about it. Querying immediately asserted on a pane
    # mid-fork, and since #649 that is legitimately `unknown`.
    #
    # Bounded, and it FAILS LOUD naming the shell rather than hanging or
    # silently accepting `unknown` — a settle that never arrives is a real
    # finding about the pane shell, not a reason to relax the assertion.
    # Grace pinned to 0 (your-org/nexus-code#777). The pane under test is
    # created moments earlier, so at the default 90 s grace it stays `unknown`
    # for the whole 10 s budget and the settle loop can never succeed — the
    # boot window is no longer a transient this test can wait out, it is the
    # deliberate answer for a pane this young. Disabling it here keeps the
    # assertion pointed at what #661 wrote it for: a SETTLED pane with nothing
    # in its tree reports `absent` with a populated name and exit 0.
    _ps661_settled=0
    _ps661_deadline=$(( SECONDS + 10 ))
    while (( SECONDS < _ps661_deadline )); do
        valid_out=$(NEXUS_PANE_BOOT_GRACE_SECONDS=0 PATH="$bogus_tmpdir:$PATH" \
            bash "$HELPER" "${bogus_session}:${valid_idx}" 2>&1)
        valid_rc=$?
        grep -qE "state=unknown[[:space:]]" <<<"$valid_out" || { _ps661_settled=1; break; }
        sleep 0.2
    done
    if (( _ps661_settled == 0 )); then
        printf '  FAIL: pane never settled within 10s (default-shell=%s) — still %q\n' \
            "${_ps661_shell:-<ambient>}" "$valid_out" >&2
        FAIL=$(( FAIL + 1 ))
    elif (( valid_rc == 0 )) \
       && grep -qE "state=absent[[:space:]]" <<<"$valid_out" \
       && grep -qE "window=${valid_idx}([[:space:]]|$)" <<<"$valid_out" \
       && grep -qE 'name=[^[:space:]]' <<<"$valid_out"; then
        printf '  PASS: valid index + SETTLED sleep pane → state=absent + populated name + rc=0\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: valid sleep-pane — rc=%s out=%q\n' \
            "$valid_rc" "$valid_out" >&2
        FAIL=$(( FAIL + 1 ))
    fi

    # Case 2b: the OTHER half of the #649 contract, pinned at the same
    # call site so the two can never drift apart again. A pane with a live
    # descendant and no claude is `unknown` — NOT `absent`, because
    # `absent` is the one kill-authorising state and must never be
    # asserted about a pane that still has something running under it.
    #
    # `test-pane-state-boot-absent.sh` covers the boundary in isolation;
    # the point here is that THIS fixture agrees with it rather than
    # contradicting it, which is exactly what went wrong in #661.
    PATH="$bogus_tmpdir:$PATH" tmux new-window -d -t "$bogus_session" \
        -n livekid "sh -c 'sleep 300 & wait'" 2>/dev/null
    live_idx=$(PATH="$bogus_tmpdir:$PATH" tmux list-windows -t "$bogus_session" \
                 -F '#{window_index} #{window_name}' | awk '$2=="livekid"{print $1}' | head -1)
    if [[ -n "$live_idx" ]]; then
        live_out=$(PATH="$bogus_tmpdir:$PATH" \
            bash "$HELPER" "${bogus_session}:${live_idx}" 2>&1)
        if grep -qE "state=unknown[[:space:]]" <<<"$live_out"; then
            printf '  PASS: live-descendant pane → state=unknown (not the kill-authorising absent)\n'
            PASS=$(( PASS + 1 ))
        else
            printf '  FAIL: live-descendant pane should be unknown — got %q\n' "$live_out" >&2
            FAIL=$(( FAIL + 1 ))
        fi
    else
        printf '  FAIL: could not create the live-descendant window\n' >&2
        FAIL=$(( FAIL + 1 ))
    fi

    cleanup_bogus
    trap - EXIT
else
    printf '  SKIP: tmux unavailable — bogus-index fail-loud tests skipped\n'
fi

echo "=== autosuggest ghost is not evidence of an empty child set (#455 follow-up) ==="
# An autosuggest ghost is a RENDERING of the input row; it says nothing about
# the process tree. The renderer ladder used to emit `autosuggest-only` WITHOUT
# ever walking the tree, so a worker holding a live background shell that drew a
# ghost on one poll read as plain-idle. The watcher then took that as an
# authoritative "no children" and silently reset its absolute ceiling.
#
# All three fixtures below are REAL captures from live worker windows.

# (14a) Ghost + LIVE background child → working-background. Deliberately uses
#       ONLY the pre-existing flags, so that when this test is run against the
#       pre-fix tree it fails on the SEMANTICS (it emits `autosuggest-only`)
#       rather than on an unknown-flag usage error. Both directions matter, so
#       14b asserts the converse.
for gf in autosuggest-why-win4 autosuggest-review-win6 autosuggest-merge-win3; do
    gfx="$FIX_DIR/$gf.ansi"
    [[ -f "$gfx" ]] || continue
    out=$("$HELPER" --fixture "$gfx" --window 9 --name ghost-live --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" --now "$ASYNC_NOW" \
                    --bg-shells 1 --bg-cpu 500 2>&1)
    if grep -qF 'state=working-background' <<<"$out" \
       && grep -qF 'bg_shells=1' <<<"$out"; then
        printf '  PASS: ghost + live child → working-background (%s)\n' "$gf"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: ghost + live child should not read idle (%s) — %s\n' "$gf" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

# (14b) Ghost with NO background child → still `autosuggest-only`. The promotion
#       must be driven by the tree, not by the ghost: no false busy-flagging of a
#       genuinely idle, ready-to-paste pane.
for gf in autosuggest-why-win4 autosuggest-review-win6 autosuggest-merge-win3; do
    gfx="$FIX_DIR/$gf.ansi"
    [[ -f "$gfx" ]] || continue
    out=$("$HELPER" --fixture "$gfx" --window 9 --name ghost-idle --active 0 \
                    --heartbeat-file "$async_tmp/missing.json" --now "$ASYNC_NOW" 2>&1)
    if grep -qF 'state=autosuggest-only' <<<"$out"; then
        printf '  PASS: ghost, no children → autosuggest-only (%s)\n' "$gf"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: childless ghost must stay autosuggest-only (%s) — %s\n' "$gf" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

echo "=== bg_oldest_start: the derived episode start (#455 follow-up) ==="
# (15) The shell-driven working-background line carries the oldest background
#      shell's start epoch, so the probe can DERIVE the episode age instead of
#      storing a resettable clock.
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name bgold --active 0 \
                --heartbeat-file "$async_tmp/missing.json" --now "$ASYNC_NOW" \
                --bg-shells 2 --bg-cpu 10 --bg-oldest-start 1699999999 2>&1)
if grep -qF 'bg_oldest_start=1699999999' <<<"$out"; then
    printf '  PASS: working-background carries bg_oldest_start\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: bg_oldest_start not emitted — %s\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== bg_cpu_bp / bg_wedged: elapsed-vs-CPU names a BLOCKED child (your-org/nexus-code#1446) ==="
# The 5h36m waiter: 428 jiffies over 20,160 s = 0.02% CPU = 2 bp. Three
# `grep -r … | head` stalls and this waiter all read `working-background`
# with nothing in the line to tell them from real compute.
_wg_now=1700000000
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name bgwedge --active 0 \
                --heartbeat-file "$async_tmp/missing.json" --now "$_wg_now" \
                --bg-shells 1 --bg-cpu 428 --bg-oldest-start $(( _wg_now - 20160 )) 2>&1)
if grep -qF 'bg_cpu_bp=2 ' <<<"$out" && grep -qF 'bg_wedged=1' <<<"$out"; then
    printf '  PASS: 428 jiffies over 5h36m → bg_cpu_bp=2 bg_wedged=1\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: wedged waiter not flagged — %s\n' "$out" >&2; FAIL=$(( FAIL + 1 ))
fi
# your-org/nexus-code#1460: the line carries a MEMBERSHIP digest of the walked
# pid tree, so the watcher can tell a static tree (a wedge) from turnover (a
# driver blocked in wait()). Overrides carry it through; absent, it reads `-`.
if grep -qF ' bg_members=- ' <<<"$out "; then
    printf '  PASS: bg_members=- when no digest was measured (override path, #1460)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: bg_members field missing or not - — %s\n' "$out" >&2; FAIL=$(( FAIL + 1 ))
fi
out_m=$("$HELPER" --fixture "$idle_fixture" --window 9 --name bgwedge --active 0 \
                --heartbeat-file "$async_tmp/missing.json" --now "$_wg_now" \
                --bg-shells 1 --bg-cpu 428 --bg-oldest-start $(( _wg_now - 20160 )) \
                --bg-members 4242424242 2>&1)
if grep -qF 'bg_members=4242424242' <<<"$out_m"; then
    printf '  PASS: --bg-members rides the line as bg_members= (#1460)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: bg_members override not emitted — %s\n' "$out_m" >&2; FAIL=$(( FAIL + 1 ))
fi
# CONTROL 1: a genuinely computing child (50% CPU) over the same episode is NOT wedged.
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name bgbusy --active 0 \
                --heartbeat-file "$async_tmp/missing.json" --now "$_wg_now" \
                --bg-shells 1 --bg-cpu 1008000 --bg-oldest-start $(( _wg_now - 20160 )) 2>&1)
if grep -qF 'bg_cpu_bp=5000 ' <<<"$out" && grep -qF 'bg_wedged=0' <<<"$out"; then
    printf '  PASS: a 50%% CPU child over the same episode is measured (5000 bp) and NOT wedged\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: computing child mis-flagged — %s\n' "$out" >&2; FAIL=$(( FAIL + 1 ))
fi
# CONTROL 2: a YOUNG episode at near-zero CPU is not wedged yet — a job that
# just started is allowed to be waiting on I/O for the first ten minutes.
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name bgyoung --active 0 \
                --heartbeat-file "$async_tmp/missing.json" --now "$_wg_now" \
                --bg-shells 1 --bg-cpu 1 --bg-oldest-start $(( _wg_now - 300 )) 2>&1)
if grep -qF 'bg_cpu_bp=0 ' <<<"$out" && grep -qF 'bg_wedged=0' <<<"$out"; then
    printf '  PASS: a 5-minute-old idle child is measured (0 bp) but NOT yet wedged\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: young episode mis-flagged — %s\n' "$out" >&2; FAIL=$(( FAIL + 1 ))
fi
# CONTROL 3: no episode start → "not measured" is distinguishable from "not wedged".
out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name bgnostart --active 0 \
                --heartbeat-file "$async_tmp/missing.json" --now "$_wg_now" \
                --bg-shells 1 --bg-cpu 1 --bg-oldest-start 0 2>&1)
if grep -qF 'bg_cpu_bp=- ' <<<"$out" && grep -qF 'bg_wedged=0' <<<"$out"; then
    printf '  PASS: unknown episode start → bg_cpu_bp=- (not measured), not wedged\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: unknown-start case — %s\n' "$out" >&2; FAIL=$(( FAIL + 1 ))
fi
# POTENCY: the threshold is a knob; raising it flips control 2 to wedged, so
# the flag is computed from the inputs rather than hard-wired to 0.
out=$(NEXUS_BG_WEDGE_MIN_ELAPSED=60 "$HELPER" --fixture "$idle_fixture" --window 9 --name bgyoung2 --active 0 \
                --heartbeat-file "$async_tmp/missing.json" --now "$_wg_now" \
                --bg-shells 1 --bg-cpu 1 --bg-oldest-start $(( _wg_now - 300 )) 2>&1)
if grep -qF 'bg_wedged=1' <<<"$out"; then
    printf '  PASS: POTENCY — with the min-elapsed knob at 60 s the same young episode IS wedged\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: knob did not flip the verdict — %s\n' "$out" >&2; FAIL=$(( FAIL + 1 ))
fi

echo
echo "=== Bypass Permissions modal names itself (your-org/nexus-code#768) ==="
# The mechanism: the binary migrates `bypassPermissionsModeAccepted` from
# `.claude.json` into `settings.json` as `skipDangerousModePermissionPrompt`
# and DELETES the original, so any between-boot rewrite of settings.json that
# does not re-supply the key wedges the next boot on this modal. The COST was
# never the wedge — it was that nothing named it: the pane read `empty`, which
# means "don't know yet", so a deterministic config fault presented as a slow
# boot and burned a probe run reported as "VI mode is unreachable".
#
# The filename-prefix harness above already asserts `blocked` for the live
# fixture and `idle` for the quoted one. These four cases assert the parts a
# prefix cannot: that the answer is SPECIFIC, that the live-ness guard is
# load-bearing rather than decorative, and that the other three overlay kinds
# did not become indistinguishable in the process.
# This file counts assertions with inline printf rather than helpers, so the
# helpers this section uses are defined here. They are NOT optional sugar: an
# earlier revision called undefined `ok`/`bad`, and the result was `command not
# found` on stderr with the counters untouched and the suite still printing ALL
# TESTS PASSED — five assertions that silently did not run. Defining them where
# they are used is what stops that recurring.
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

bp_live="$FIX_DIR/blocked-bypass-permissions-synthetic.ansi"
bp_quoted="$FIX_DIR/idle-bypass-modal-quoted-synthetic.ansi"
[[ -f "$bp_live"   ]] || { echo "needs $bp_live" >&2; exit 1; }
[[ -f "$bp_quoted" ]] || { echo "needs $bp_quoted" >&2; exit 1; }

# (1) The live modal is named, not merely classified.
out=$("$HELPER" --fixture "$bp_live" --window 9 --name bpwin --active 0 2>&1)
if grep -qF 'state=blocked' <<<"$out" && grep -qF 'overlay=bypass-permissions' <<<"$out"; then
    printf '  PASS: live modal → state=blocked overlay=bypass-permissions (the failure says its own name)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: live modal — want state=blocked + overlay=bypass-permissions, got: %s\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# (2) NEGATIVE CONTROL, and the reason this arm needed a live-ness guard at
#     all: the modal's text is quoted in issue #768, in pane-state.sh's own
#     comment, and in synthesize.sh — so an agent READING any of them has
#     every shape literal on screen. A pane that merely displays the words
#     must stay idle.
out=$("$HELPER" --fixture "$bp_quoted" --window 9 --name bpwin --active 0 2>&1)
if grep -qF 'state=idle' <<<"$out" && ! grep -qF 'overlay=' <<<"$out"; then
    printf '  PASS: a pane merely QUOTING the modal stays idle (no overlay= claim)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: quoted modal — want state=idle and no overlay=, got: %s\n' "$out" >&2
    FAIL=$(( FAIL + 1 ))
fi

# (2b) THE BOUNDARY, constructed by the #776 skeptic and kept as a fixture.
#      Case (2)'s fixture happens to carry four non-blank chrome rows below the
#      quoted footer; against a `tail -n 3` window that is a 2-row margin, and
#      the skeptic built the pane that eats it — an idle agent quoting the modal
#      with only two rows below, which the bottom-slice guard alone classified
#      `blocked`. A non-vacuity mutation does not probe a boundary; this does.
bp_edge="$FIX_DIR/idle-bypass-modal-quoted-boundary-synthetic.ansi"
[[ -f "$bp_edge" ]] || { echo "needs $bp_edge" >&2; exit 1; }
out=$("$HELPER" --fixture "$bp_edge" --window 9 --name bpwin --active 0 2>&1)
if grep -qF 'state=idle' <<<"$out" && ! grep -qF 'overlay=' <<<"$out"; then
    ok "the 2-row-margin boundary pane stays idle (the margin is no longer what decides)"
else
    bad "boundary pane" "want state=idle and no overlay=, got: $out"
fi

# (2c) …and the STRUCTURAL test is what rejects it, not the margin. Widen the
#      slice to something no realistic pane could fail and the boundary pane
#      must STILL be idle — if it flips, the margin is secretly load-bearing
#      again and the #776 finding has been reintroduced under a bigger number.
#
#      #896 added a SECOND arm (`_has_menu_dialog_frame`) using the same
#      bottom-slice idiom, so the mutation now widens EVERY occurrence rather
#      than the first. That is the stronger claim, not a concession: with the
#      margin removed from every arm that has one, the boundary pane must still
#      be idle, which can only be the REPL-row test doing it.
bp_wide=$(mktemp)
python3 - "$HELPER" "$bp_wide" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = "| grep -v '^[[:space:]]*$' | tail -n 3)\" || return 1"
new = "| grep -v '^[[:space:]]*$' | tail -n 99)\" || return 1"
assert s.count(old) >= 1, "slice expression not found — the mutation is a no-op"
open(dst, 'w').write(s.replace(old, new))
PY
chmod +x "$bp_wide"
out=$(bash "$bp_wide" --fixture "$bp_edge" --window 9 --name bpwin --active 0 2>&1)
if grep -qF 'state=idle' <<<"$out"; then
    ok "with the slice widened to 99 the boundary pane is STILL idle — the REPL-row test carries it, not the margin"
else
    bad "structural test" "widening the slice flipped the boundary pane to blocked, so the margin is still the discriminator: $out"
fi
rm -f "$bp_wide"

# (3) BOTH live-ness tests are LOAD-BEARING, each proven by mutation against the
#     pane only IT catches. With two guards, removing one and watching a single
#     fixture proves nothing — the survivor still rejects it — so each mutation
#     is paired with the shape that isolates it:
#
#       structural (no REPL row below the footer) → the BOUNDARY pane, whose
#           footer sits inside the slice and which only the REPL-row test rejects
#       bottom-slice (footer near the end)        → a pane quoting the modal high
#           up with no REPL row below it at all, which only the slice rejects
#
#     Each mutation is applied in python against exact source text and asserts it
#     matched, so a reworded guard fails loudly instead of mutating nothing and
#     reporting a pass.
bp_mut=$(mktemp); trap 'rm -f "$bp_mut" "$bp_high"' EXIT

_bp_mutate() {   # _bp_mutate <marker> <python-body-file-content via stdin>
    python3 - "$HELPER" "$bp_mut" "$1" <<'PY'
import sys
src, dst, which = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
if which == 'structural':
    guard = ('    if grep -qF "❯${NBSP}" <<<"$(tail -n +"$(( footer_ln + 1 ))" <<<"$plain")"; then\n'
             '        return 1   # a REPL input row lives below the footer ⇒ the pane is quoting\n'
             '    fi\n')
else:
    guard = ("    grep -qF 'Enter to confirm' \\\n"
             "        <<<\"$(printf '%s\\n' \"$plain\" | grep -v '^[[:space:]]*$' | tail -n 3)\" || return 1\n")
if s.count(guard) != 1:
    sys.exit("MUTATION TARGET NOT FOUND (%s): found %d" % (which, s.count(guard)))
open(dst, 'w').write(s.replace(guard, "    : # %s live-ness test REMOVED by mutation\n" % which, 1))
PY
}

# (3a) structural test, isolated by the boundary pane.
if ! _bp_mutate structural; then
    bad "mutation (structural)" "could not locate the REPL-row test to remove — this assertion has gone vacuous"
elif ! bash -n "$bp_mut" 2>/dev/null; then
    bad "mutation (structural)" "the mutated helper does not parse; the mutation missed its target"
else
    chmod +x "$bp_mut"
    out=$(bash "$bp_mut" --fixture "$bp_edge" --window 9 --name bpwin --active 0 2>&1)
    if grep -qF 'state=blocked' <<<"$out"; then
        ok "removing the REPL-row test flips the BOUNDARY pane to blocked — it is what rejects it (#776 skeptic finding e)"
    else
        bad "mutation (structural)" "without the REPL-row test the boundary pane should false-positive, got: $out"
    fi
fi

# (3b) bottom-slice test, isolated by a pane quoting the modal high up with NO
#      REPL row below it — the structural test has nothing to catch, so only the
#      slice can reject it.
bp_high=$(mktemp)
{
    printf '%s\n' '  WARNING: Claude Code running in Bypass Permissions mode'
    printf '%s\n' '    2. Yes, I accept'
    printf '%s\n' '  Enter to confirm · Esc to cancel'
    for _i in 1 2 3 4 5; do printf '%s\n' '  ...transcript continues, no input row captured...'; done
} > "$bp_high"
out=$("$HELPER" --fixture "$bp_high" --window 9 --name bpwin --active 0 2>&1)
if ! grep -qF 'overlay=bypass-permissions' <<<"$out"; then
    ok "a modal quoted high in the pane is rejected (footer outside the bottom slice)"
else
    bad "high-quote pane" "want no overlay= claim, got: $out"
fi
if ! _bp_mutate slice; then
    bad "mutation (slice)" "could not locate the bottom-slice test to remove — this assertion has gone vacuous"
elif ! bash -n "$bp_mut" 2>/dev/null; then
    bad "mutation (slice)" "the mutated helper does not parse; the mutation missed its target"
else
    chmod +x "$bp_mut"
    out=$(bash "$bp_mut" --fixture "$bp_high" --window 9 --name bpwin --active 0 2>&1)
    if grep -qF 'overlay=bypass-permissions' <<<"$out"; then
        ok "removing the bottom-slice test flips the high-quote pane — it too is load-bearing, not redundant"
    else
        bad "mutation (slice)" "without the slice test the high-quote pane should false-positive, got: $out"
    fi
fi

# (4) The other three overlay kinds stay distinguishable. `blocked` was already
#     correct for all four; the regression this guards is a future edit that
#     collapses them to one label, which would put the diagnosis back where
#     #768 found it.
for pair in "blocked-permission-synthetic:permission" \
            "blocked-ratelimit-synthetic:rate-limit" \
            "blocked-askuq-synthetic:askuq"; do
    bp_f="${pair%%:*}"; bp_want="${pair##*:}"
    out=$("$HELPER" --fixture "$FIX_DIR/$bp_f.ansi" --window 9 --name bpwin --active 0 2>&1)
    if grep -qF "overlay=$bp_want" <<<"$out"; then
        printf '  PASS: %-34s → overlay=%s\n' "$bp_f" "$bp_want"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — want overlay=%s, got: %s\n' "$bp_f" "$bp_want" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

# ── your-org/nexus-code#801: dim BOX CHROME is not ghost text ──────────────
#
# `_detect_dim_run` searched `${input_row#*❯}` — everything after the chevron
# TO END OF LINE — for a faint run carrying a visible character. A dim closing
# box border is exactly that, so an EMPTY input box drawn with one classified
# `autosuggest-only input=ghost`, and `state=idle` became UNREACHABLE for that
# renderer (measured deterministically over a 28 s poll against the
# integration stub, `#798`).
#
# The three fixtures below are the coverage boundary of that fix, chosen so
# that no single wrong fix passes all three:
#
#   idle-empty-*      the NEGATIVE control — an empty box WITH a border must
#                     read idle/blank. Nothing covered this, which is how the
#                     defect survived.
#   autosuggest-*     the POSITIVE control — REAL ghost bytes in the SAME
#                     bordered box must still read autosuggest-only/ghost. A
#                     "fix" that stopped detecting dim runs passes the first
#                     fixture and fails here.
#   user-typing-*     the KILL-AXIS control — vim INSERT, real operator text,
#                     no bright marker. Pre-fix this read autosuggest-only /
#                     input=ghost: a kill-authorised state AND a safe-to-paste
#                     token, both about the operator's own words.
#
# `state=` alone is asserted by the filename-prefix sweep at the top of this
# file. `input=` is asserted HERE because it is a SEPARATE contract read by a
# different consumer (pasting, not retirement) and the prefix sweep is blind
# to it — half of #801's consequence lives on that axis.
echo
echo "=== #801: dim box chrome vs ghost text ==="
#   *-adjacent-*      the RUN-STRUCTURE control (skeptic F1). The glyph
#                     manifest varies WHICH glyph; the mechanism also varies
#                     HOW MANY dim introducers the renderer emits across the
#                     border. A single `s///g` pass consumed the terminating
#                     ESC and resumed after it, so adjacent runs were stripped
#                     alternately and ONE SURVIVED — `#801` intact on a doubled
#                     border. Two axes, both pinned.
for pair in "idle-empty-dim-box-border-synthetic:idle:blank" \
            "autosuggest-dim-box-border-synthetic:autosuggest-only:ghost" \
            "user-typing-vim-dim-box-border-synthetic:user-typing:typed" \
            "idle-empty-adjacent-dim-border-synthetic:idle:blank" \
            "user-typing-vim-adjacent-dim-border-synthetic:user-typing:typed" \
            "user-typing-vim-tripled-dim-border-synthetic:user-typing:typed"; do
    ch_f="${pair%%:*}"; ch_rest="${pair#*:}"
    ch_state="${ch_rest%%:*}"; ch_input="${ch_rest##*:}"
    out=$("$HELPER" --fixture "$FIX_DIR/$ch_f.ansi" --window 9 --name chwin --active 0 2>&1)
    got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got_state" == "$ch_state" ]] && grep -qE "(^| )input=$ch_input( |$)" <<<"$out"; then
        printf '  PASS: %-44s → state=%s input=%s\n' "$ch_f" "$ch_state" "$ch_input"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — want state=%s input=%s, got: %s\n' \
            "$ch_f" "$ch_state" "$ch_input" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

# MUTATION. Neutering `_strip_dim_box_chrome` to the identity must flip ALL
# THREE fixtures back to the pre-fix reading. Without this the three
# assertions above are satisfied by a classifier that never looked at chrome
# at all — they would pass on any tree where the fixtures happen to classify
# correctly for some other reason, which is precisely the vacuous green this
# repo keeps meeting. The mutation is applied against exact source text and
# asserts it matched, so a renamed helper fails loudly rather than mutating
# nothing and reporting a pass.
ch_mut=$(mktemp); trap 'rm -f "$bp_mut" "$bp_high" "$ch_mut"' EXIT
if ! python3 - "$HELPER" "$ch_mut" <<'PYMUT'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
marker = '_strip_dim_box_chrome() {\n'
if s.count(marker) != 1:
    sys.exit("MUTATION TARGET NOT FOUND: _strip_dim_box_chrome() defined %d time(s)" % s.count(marker))
s = s.replace(marker, marker + '    printf %s "$1"; return 0   # MUTATION: chrome stripping REMOVED\n', 1)
open(dst, 'w').write(s)
PYMUT
then
    printf '  FAIL: mutation — could not locate _strip_dim_box_chrome; this section has gone vacuous\n' >&2
    FAIL=$(( FAIL + 1 ))
elif ! bash -n "$ch_mut" 2>/dev/null; then
    printf '  FAIL: mutation — the mutated helper does not parse; the mutation missed its target\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    chmod +x "$ch_mut"
    ch_flipped=0
    for ch_f in idle-empty-dim-box-border-synthetic \
                autosuggest-dim-box-border-synthetic \
                user-typing-vim-dim-box-border-synthetic \
                idle-empty-adjacent-dim-border-synthetic \
                user-typing-vim-adjacent-dim-border-synthetic \
                user-typing-vim-tripled-dim-border-synthetic; do
        out=$(bash "$ch_mut" --fixture "$FIX_DIR/$ch_f.ansi" --window 9 --name chwin --active 0 2>&1)
        # Pre-fix, every one of the three read `autosuggest-only input=ghost`:
        # the border satisfies the dim-run test, and that branch is evaluated
        # before the empty-box arm, so all three collapse onto it.
        if grep -qE '(^| )state=autosuggest-only( |$)' <<<"$out" \
           && grep -qE '(^| )input=ghost( |$)' <<<"$out"; then
            ch_flipped=$(( ch_flipped + 1 ))
        else
            printf '  note: %s did NOT collapse under mutation: %s\n' "$ch_f" "$out" >&2
        fi
    done
    if (( ch_flipped >= 5 )); then
        printf '  PASS: removing the chrome strip collapses the chrome fixtures to autosuggest-only/ghost — it is what decides them\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: mutation — only %d/5 fixtures flipped; the chrome strip is not what these assertions measure\n' \
            "$ch_flipped" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

echo
echo "=== #896: a select-dialog is recognised STRUCTURALLY, not by its wording ==="
# The motivating instance is Claude Code's workspace-trust dialog: 2.1.232
# stopped letting nested git repos inherit trust from a parent, so every
# `work/<project>` worker spawn boots into it. pane-state read the frame as
# `state=empty active=0` — "don't know yet" — so `_unstick.sh` never fired (its
# case_B needs `blocked`) and a worker that would NEVER proceed was
# indistinguishable from one that had merely not started.
#
# The trust dialog is ONE INSTANCE. These assertions are shaped around the
# CLASS, and split along the two failure directions the fix has to survive:
#
#   CAN IT FIRE?   the live-captured trust frame, and an invented dialog whose
#                  wording exists nowhere, must both classify `blocked`.
#   CAN IT STAY SILENT?  four near-miss panes — each failing exactly ONE of the
#                  arm's three conditions — must stay unblocked, and every
#                  other committed fixture must acquire no `overlay=` at all.
#
# Direction 2 is the one that decides whether the fix is real: a detector that
# always fires is the same defect as one that never does, failing toward the
# other side.
md_live="$FIX_DIR/blocked-workspace-trust-realmodel.ansi"
# The SECOND live capture (your-org/nexus-code#1112). 2.1.248 dropped the `N.`
# ordinals from this dialog and reordered its options, breaking the ordinal-keyed
# form of condition (b) and putting every trust-dialog pane back on `empty`. Both
# captures are committed and both must classify, because the operator's pin is
# 2.1.246 and the candidate stream is >=2.1.248: a fix that trades one rendering
# for the other is not a fix.
md_live248="$FIX_DIR/blocked-workspace-trust-realmodel-248.ansi"
md_unnamed="$FIX_DIR/blocked-unnamed-dialog-synthetic.ansi"
md_quoted="$FIX_DIR/idle-trust-dialog-quoted-synthetic.ansi"
md_quoted248="$FIX_DIR/idle-trust-dialog-248-quoted-synthetic.ansi"
for _f in "$md_live" "$md_live248" "$md_unnamed" "$md_quoted" "$md_quoted248"; do
    [[ -f "$_f" ]] || { echo "needs $_f" >&2; exit 1; }
done

# (1) The live capture — from the REAL binary, not transcribed from a PR body
#     (see test-integration/test-realmodel-trust-dialog.sh, which re-derives it).
out=$("$HELPER" --fixture "$md_live" --window 9 --name mdwin --active 0 2>&1)
if grep -qF 'state=blocked' <<<"$out" && grep -qF 'overlay=workspace-trust' <<<"$out"; then
    ok "the live-captured trust dialog → state=blocked overlay=workspace-trust"
else
    bad "live trust dialog" "want state=blocked + overlay=workspace-trust, got: $out"
fi

# (1b) THE SAME DIALOG AS 2.1.248 RENDERS IT — no ordinals, options reordered,
#      everything else identical. Also a real capture from the real binary
#      (2.1.248 in a throwaway prefix, one sequential harness boot), not a
#      transcription. This is the assertion #1112 exists for.
out=$("$HELPER" --fixture "$md_live248" --window 9 --name mdwin --active 0 2>&1)
if grep -qF 'state=blocked' <<<"$out" && grep -qF 'overlay=workspace-trust' <<<"$out"; then
    ok "the 2.1.248 trust dialog (ordinals DROPPED) → state=blocked overlay=workspace-trust"
else
    bad "2.1.248 trust dialog" "want state=blocked + overlay=workspace-trust, got: $out"
fi

# (2) THE CLASS ASSERTION. A dialog whose wording appears in no Claude Code
#     release and nowhere else in this repo. A text-keyed fix passes (1) and
#     fails this; that difference is the entire point of the change.
out=$("$HELPER" --fixture "$md_unnamed" --window 9 --name mdwin --active 0 2>&1)
if grep -qF 'state=blocked' <<<"$out" && grep -qF 'overlay=dialog' <<<"$out"; then
    ok "a dialog nobody enumerated → state=blocked overlay=dialog (the class, not the instance)"
else
    bad "unnamed dialog" "want state=blocked + overlay=dialog, got: $out"
fi

# (2b) …and the naming table really is naming-only. Break the trust literals in
#      `_name_menu_dialog_kind` and the LIVE capture must STILL be `blocked` —
#      just under the generic kind. If it falls back to `empty`, detection was
#      quietly depending on the wording after all.
md_mut=$(mktemp); trap 'rm -f "$bp_mut" "$bp_high" "$md_mut" "${md_high:-}"' EXIT
python3 - "$HELPER" "$md_mut" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# Blind BOTH literals of the naming arm — one is not enough, since the arm is
# an OR and the live frame carries the prose form as well as the option label.
old = ("    if grep -qF 'trust this folder' <<<\"$plain\" \\\n"
       "       || grep -qE 'Is this a project you created or one you trust\\?' <<<\"$plain\"; then\n")
if s.count(old) != 1:
    sys.exit("MUTATION TARGET NOT FOUND: _name_menu_dialog_kind trust arm, found %d" % s.count(old))
new = "    if grep -qF 'ZZZ-no-such-literal-ZZZ' <<<\"$plain\"; then\n"
open(dst, 'w').write(s.replace(old, new, 1))
PY
if [[ ! -s "$md_mut" ]]; then
    bad "mutation (naming)" "could not rewrite the naming table — this assertion has gone vacuous"
elif ! bash -n "$md_mut" 2>/dev/null; then
    bad "mutation (naming)" "the mutated helper does not parse; the mutation missed its target"
else
    out=$(bash "$md_mut" --fixture "$md_live" --window 9 --name mdwin --active 0 2>&1)
    if grep -qF 'state=blocked' <<<"$out" && grep -qF 'overlay=dialog' <<<"$out"; then
        ok "blinding the naming table leaves the live trust dialog BLOCKED (kind falls back to dialog) — detection is not text-keyed"
    else
        bad "mutation (naming)" "want state=blocked + overlay=dialog with the literals blinded, got: $out"
    fi
fi

# --- direction 2: can it stay silent? -------------------------------------
#
# (3) A running agent QUOTING the trust dialog. Every literal is on screen —
#     the wording lives in the issue, in pane-state.sh's comment, and in
#     synthesize.sh — so the shape alone would fire.
#
#     WHAT REJECTS IT IS CONDITION (a), NOT (c). This comment used to credit the
#     REPL-row test ("a live dialog REPLACES the REPL, and this pane still has
#     its input row"), which reads plausibly and is wrong: measured by removing
#     (c) and re-running, this fixture is STILL `idle`. Its REPL chrome pushes
#     the quoted footer out of the bottom slice, so (a) rejects it first and (c)
#     never gets a say. The `-boundary-` fixture below is the one (c) rejects,
#     and the mutation table uses it — so the COVERAGE was right and only the
#     attribution was wrong (#896 skeptic, Finding 4). Recorded rather than
#     silently corrected, because "the assertion passes" and "the assertion
#     measures what its comment says" are different claims.
out=$("$HELPER" --fixture "$md_quoted" --window 9 --name mdwin --active 0 2>&1)
if grep -qF 'state=idle' <<<"$out" && ! grep -qF 'overlay=' <<<"$out"; then
    ok "a pane QUOTING the trust dialog stays idle (no overlay= claim)"
else
    bad "quoted trust dialog" "want state=idle and no overlay=, got: $out"
fi

# (3b) THE SAME, FOR THE UNNUMBERED RENDERING — and it matters MORE than (3).
#      Widening (b) from `❯ N.` to a column-aligned cursor row makes this frame
#      EASIER to match, so the live-vs-quoted guard is now carrying more weight
#      than it was. This pane keeps its footer INSIDE the bottom slice and its
#      REPL row below it, so (c) is the condition doing the rejecting here.
out=$("$HELPER" --fixture "$md_quoted248" --window 9 --name mdwin --active 0 2>&1)
if grep -qF 'state=idle' <<<"$out" && ! grep -qF 'overlay=' <<<"$out"; then
    ok "a pane QUOTING the 2.1.248 (unnumbered) dialog stays idle (no overlay= claim)"
else
    bad "quoted 2.1.248 dialog" "want state=idle and no overlay=, got: $out"
fi

# (4) The four near-misses, one per condition. Each must classify as it did
#     before this change — the `busy-` prefix loop above already asserts that;
#     what these add is that none of them acquired an `overlay=` claim, which
#     the prefix check cannot see.
declare -A md_near=(
    ["busy-menu-no-footer-synthetic.ansi"]="a menu-shaped list with no Enter/Esc affordance"
    ["busy-footer-plain-list-synthetic.ansi"]="a footer over a list with no highlighted choice"
    ["busy-footer-aligned-list-no-cursor-synthetic.ansi"]="a footer over a COLUMN-ALIGNED list with no cursor (the shape the ordinal-free rule must still refuse)"
    ["busy-footer-single-option-synthetic.ansi"]="a footer over a SINGLE option (one choice is not a menu)"
    ["busy-esc-to-interrupt-menu-synthetic.ansi"]="the spinner's own lowercase 'esc to interrupt'"
    ["busy-dialog-quoted-midrender-synthetic.ansi"]="a BUSY pane quoting the dialog, mid-render (no chevron at all)"
    ["busy-dialog-quoted-queued-synthetic.ansi"]="a BUSY pane quoting the dialog with a message QUEUED behind the turn"
)
for md_f in "${!md_near[@]}"; do
    [[ -f "$FIX_DIR/$md_f" ]] || { echo "needs $FIX_DIR/$md_f" >&2; exit 1; }
    out=$("$HELPER" --fixture "$FIX_DIR/$md_f" --window 9 --name mdwin --active 0 2>&1)
    if grep -qF 'state=busy' <<<"$out" && ! grep -qF 'overlay=' <<<"$out"; then
        ok "near-miss stays busy: ${md_near[$md_f]}"
    else
        bad "near-miss $md_f" "want state=busy and no overlay=, got: $out"
    fi
done

# (4b) THE FIELD THE PREFIX CANNOT SEE. `busy-*` gets `state=busy` from the
#      filename loop, but `queued=1` is what CLAUDE.md cites as "input already
#      waiting behind a running turn — do not paste into it again", and the
#      first version of this arm SWALLOWED it: `busy queued=1` became `blocked
#      overlay=workspace-trust`, because `_has_blocked_overlay` runs ahead of
#      the queued-message check. A `state=busy` assertion alone would have
#      passed on a pane that had lost the field. Assert the field.
out=$("$HELPER" --fixture "$FIX_DIR/busy-dialog-quoted-queued-synthetic.ansi" \
        --window 9 --name mdwin --active 0 2>&1)
if grep -qF 'state=busy' <<<"$out" && grep -qE '(^| )queued=1( |$)' <<<"$out"; then
    ok "the queued-message pane keeps queued=1 (the do-not-paste signal survives the overlay arm)"
else
    bad "queued pane" "want state=busy AND queued=1, got: $out"
fi

# (5) THE SWEEP. Every committed fixture, not just the ones this section names:
#     exactly the `blocked-*` set may carry an `overlay=`, and nothing else may.
#     This is the assertion that notices a future widening of the arm even if
#     nobody thinks to add a fixture for what it broke.
# THE EXPECTATION COMES FROM THE MANIFEST, NOT FROM THE FILENAME
# (your-org/nexus-code#1214 skeptic F2). This sweep used to read
# `case "$(basename "$md_f")" in blocked-*)`, which is the FILENAME-PREFIX
# scheme `#1176` removed -- surviving inside the very file that removed it, and
# ruling on all 57 fixtures. It made the manifest's own promise ("a fixture's
# name is now free to DESCRIBE the capture") false as shipped, and it was
# exercised by a rename: renaming `blocked-askuq-synthetic.ansi` with its
# manifest row updated and the classifier byte-identical turned the suite red
# for the wrong reason.
#
# The BARE row (env `-`, args `-`) is the one that speaks for the fixture read
# with no scenario, which is exactly how this sweep reads it.
#
# A fixture with NO manifest row is RED, not silently non-blocked: an unknown
# expectation must never take the permissive arm.
md_leaked=0 md_missing=0 md_unknown=0
_md_want() {                       # _md_want <basename> -> bare-row want, or ""
    local want="" b="$1" m_f m_w m_e m_a m_r
    while IFS=$'\t' read -r m_f m_w m_e m_a m_r; do
        [[ "$m_f" == "$b" ]] || continue
        [[ "$m_e" == "-" && "$m_a" == "-" ]] || continue
        want="$m_w"; break
    done <<<"$manifest_rows"
    printf '%s' "$want"
}
for md_f in "$FIX_DIR"/*.ansi; do
    out=$("$HELPER" --fixture "$md_f" --window 9 --name mdwin --active 0 2>&1)
    md_b=$(basename "$md_f")
    md_w=$(_md_want "$md_b")
    if [[ -z "$md_w" ]]; then
        md_unknown=$(( md_unknown + 1 ))
        printf '  note: %s has no bare manifest row — expectation UNKNOWN, refusing to assume\n' "$md_b" >&2
    elif [[ "$md_w" == "blocked" ]]; then
        grep -qF 'overlay=' <<<"$out" || {
            md_missing=$(( md_missing + 1 ))
            printf '  note: %s is manifest-blocked but carries no overlay=: %s\n' "$md_b" "$out" >&2
        }
    else
        grep -qF 'overlay=' <<<"$out" && {
            md_leaked=$(( md_leaked + 1 ))
            printf '  note: %s is manifest-%s but claims an overlay: %s\n' "$md_b" "$md_w" "$out" >&2
        }
    fi
done
if (( md_leaked == 0 && md_missing == 0 && md_unknown == 0 )); then
    ok "overlay= appears on exactly the manifest-blocked fixtures and no others (swept all ${#fixtures[@]})"
else
    # NAME EVERY COUNTER THE CONDITION TESTS (your-org/nexus-code#1214 D4).
    # This message omitted md_unknown, so a fixture with NO manifest row --
    # the arm added to stop an unknown expectation taking the permissive
    # branch -- failed with "0 non-blocked … 0 blocked …", i.e. a failure
    # reporting two zeroes and never naming its own cause.
    bad "overlay sweep" "$md_leaked manifest-non-blocked fixtures claimed an overlay, $md_missing manifest-blocked fixtures carried none, $md_unknown fixtures had NO manifest row (expectation unknown — refused rather than assumed)"
fi

# (6) EACH of the three conditions is load-bearing, proven by mutation against
#     the near-miss that ONLY it rejects. Removing a condition and watching a
#     fixture no other condition would have caught is what separates a guard
#     from a comment. Every mutation asserts it matched its target, so a
#     reworded condition fails loudly instead of mutating nothing and passing.
_md_mutate() {   # _md_mutate <which>
    python3 - "$HELPER" "$md_mut" "$1" <<'PY'
import sys
src, dst, which = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
SLICE = ("    grep -qE \"$footer_re\" \\\n"
         "        <<<\"$(printf '%s\\n' \"$plain\" | grep -v '^[[:space:]]*$' | tail -n 3)\" || return 1\n")
# The (d) guard, hoisted because three of the mutations below must remove it
# FIRST. Their near-miss panes are BUSY — which is how these shapes actually
# appear in production — so after #896's skeptic added (d) those panes fail TWO
# conditions, and removing only the intended one leaves (d) still rejecting
# them. That is correct behaviour and a VACUOUS mutation: it would have reported
# "the guard is load-bearing" while measuring nothing. Composing the removal
# keeps the claim honest and narrows it to what it can support — "given (d) is
# gone, THIS is what rejects the pane".
WORKING = ('    if _detect_busy "$plain" "$(wc -l <<<"$plain")" \\\n'
           '       || _detect_queued_message "$plain"; then\n'
           '        return 1\n'
           '    fi\n')
targets = {
  # (a) a navigation footer, in the BOTTOM SLICE — the dialog is live rather
  #     than quoted high in a transcript.
  #
  #     NOT mutated separately: the arm's `[[ -n "$footer_ln" ]] || return 1`.
  #     It looks like a second condition and is not — the slice grep already
  #     proves a footer exists somewhere, so the emptiness check is DEAD as a
  #     discriminator and no pane can isolate it. It stays in the source as a
  #     `set -u` guard against a future edit that decouples the two greps.
  #     Writing a mutation for it would have produced a passing assertion
  #     measuring nothing, which is the failure mode this whole section is
  #     shaped against.
  'slice': [SLICE],
  # (b1) the highlighted-choice requirement. No longer keyed on `N.` ordinals
  #      (your-org/nexus-code#1112) — 2.1.248 dropped those — so the guard being
  #      removed is now the emptiness check on the cursor-row search.
  'chevron': [WORKING, '    [[ -n "$sel_line" ]] || return 1\n'],
  # (b2) the sibling floor: one option is not a menu. Under #1112 the sibling is
  #      identified by COLUMN ALIGNMENT rather than by carrying an ordinal.
  'siblings': [WORKING, '    grep -qE "$sib_re" <<<"$above" || return 1\n'],
  # (c) live-vs-quoted: no REPL row below the footer
  'repl': ['    if grep -qF "❯${NBSP}" <<<"$(tail -n +"$(( footer_ln + 1 ))" <<<"$plain")"; then\n'
           '        return 1\n'
           '    fi\n'],
  # the footer regex's case-sensitivity
  'case': [WORKING, "    local footer_re='(Enter|Esc) to [a-z]'\n"],
  # (d) positive evidence the agent is WORKING. The condition the #896 skeptic's
  #     attack forced: (c) is an ABSENCE test, and two documented regimes have a
  #     live REPL painting no `❯<NBSP>` row, so (c) goes inert exactly when a
  #     busy pane quotes a dialog.
  'working': [WORKING],
}
for guard in targets[which]:
    if s.count(guard) != 1:
        sys.exit("MUTATION TARGET NOT FOUND (%s): found %d" % (which, s.count(guard)))
    if which == 'case':
        repl = "    local footer_re='(Enter|Esc|enter|esc) to [a-z]'\n"
    else:
        repl = "    : # %s condition REMOVED by mutation\n" % which
    s = s.replace(guard, repl, 1)
open(dst, 'w').write(s)
PY
}

#      The bottom-slice condition needs a pane no COMMITTED fixture supplies: a
#      dialog quoted high in a transcript whose own REPL row has scrolled out of
#      the capture, so the REPL-row test has nothing to catch and only the slice
#      can reject it. Built here rather than committed because it is a mutation
#      instrument, not a shape production renders.
md_high=$(mktemp)
{
    printf '%s\n' '● Read(reports/nexus_2026-08-14_trust.md)'
    printf '%s\n' '    ❯ 1. Yes, I trust this folder'
    printf '%s\n' '      2. No, exit'
    printf '%s\n' '    Enter to confirm · Esc to cancel'
    for _i in 1 2 3 4 5; do printf '%s\n' '  ...transcript continues, no input row captured...'; done
} > "$md_high"
out=$("$HELPER" --fixture "$md_high" --window 9 --name mdwin --active 0 2>&1)
if ! grep -qF 'overlay=' <<<"$out"; then
    ok "a dialog quoted high in the pane is rejected (footer outside the bottom slice)"
else
    bad "high-quote pane" "want no overlay= claim, got: $out"
fi

# which condition, which pane it uniquely rejects, and what the pane must
# become once that condition is gone. `-` in the fixture column means the
# inline `$md_high` pane above.
md_cases=(
    "slice|-|the navigation-footer requirement (present, and near the end)"
    "chevron|busy-footer-aligned-list-no-cursor-synthetic.ansi|the highlighted-choice (❯) requirement (with the agent-is-working test already removed)"
    "siblings|busy-footer-single-option-synthetic.ansi|the sibling floor (with the agent-is-working test already removed)"
    "repl|idle-trust-dialog-quoted-boundary-synthetic.ansi|the live-vs-quoted REPL-row test"
    "case|busy-esc-to-interrupt-menu-synthetic.ansi|the footer's case-sensitivity (with the agent-is-working test already removed)"
    "working|busy-dialog-quoted-midrender-synthetic.ansi|the agent-is-working test"
    "working|busy-dialog-quoted-queued-synthetic.ansi|the agent-is-working test (queued regime)"
)
for md_case in "${md_cases[@]}"; do
    IFS='|' read -r md_which md_fix md_label <<<"$md_case"
    md_path="$FIX_DIR/$md_fix"
    [[ "$md_fix" == "-" ]] && { md_path="$md_high"; md_fix="the high-quote pane"; }
    [[ -f "$md_path" ]] || { echo "needs $md_path" >&2; exit 1; }
    if ! _md_mutate "$md_which"; then
        bad "mutation ($md_which)" "could not locate $md_label — this assertion has gone vacuous"
        continue
    fi
    if ! bash -n "$md_mut" 2>/dev/null; then
        bad "mutation ($md_which)" "the mutated helper does not parse; the mutation missed its target"
        continue
    fi
    out=$(bash "$md_mut" --fixture "$md_path" --window 9 --name mdwin --active 0 2>&1)
    if grep -qF 'state=blocked' <<<"$out"; then
        ok "removing $md_label flips $md_fix to blocked — it is what rejects that pane"
    else
        bad "mutation ($md_which)" "without $md_label, $md_fix should false-positive, got: $out"
    fi
done
rm -f "$md_mut" "$md_high"

# (6b) THE #1112 GATE, in the direction that actually failed. Every mutation
#      above removes a condition and watches a near-miss become `blocked` —
#      the "can it stay silent?" direction. The 2.1.248 regression failed the
#      OTHER way: a condition that was too NARROW, so a live dialog stayed
#      `empty`. A removal mutation cannot see that, because removing a
#      too-narrow condition only makes it fire more.
#
#      So this one RE-INSTATES the ordinal requirement #1112 removed —
#      reproducing the exact pre-fix source — and asserts the split it caused:
#      the 2.1.246 capture still classifies, the 2.1.248 capture does NOT. A
#      fix that quietly kept keying on `N.` and passed (1b) some other way
#      would fail here, and so would one that stopped classifying 2.1.246.
md_mut=$(mktemp)
python3 - "$HELPER" "$md_mut" <<'PY_ORD'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = """    sel_line=$(grep -E '^ *\u276f +[^ ]' <<<"$above" | tail -1)\n"""
if s.count(old) != 1:
    sys.exit("MUTATION TARGET NOT FOUND: cursor-row search, found %d" % s.count(old))
new = """    sel_line=$(grep -E '^ *\u276f +[0-9]+\\.[ ]' <<<"$above" | tail -1)\n"""
open(dst, 'w').write(s.replace(old, new, 1))
PY_ORD
if [[ ! -s "$md_mut" ]]; then
    bad "mutation (ordinals)" "could not re-instate the ordinal requirement — this assertion has gone vacuous"
elif ! bash -n "$md_mut" 2>/dev/null; then
    bad "mutation (ordinals)" "the mutated helper does not parse; the mutation missed its target"
else
    out246=$(bash "$md_mut" --fixture "$md_live" --window 9 --name mdwin --active 0 2>&1)
    out248=$(bash "$md_mut" --fixture "$md_live248" --window 9 --name mdwin --active 0 2>&1)
    if grep -qF 'overlay=workspace-trust' <<<"$out246" && ! grep -qF 'overlay=' <<<"$out248"; then
        ok 're-instating the chevron-plus-ordinal requirement reproduces #1112 exactly: 2.1.246 still classifies, 2.1.248 goes blind'
    else
        bad "mutation (ordinals)" "want 2.1.246 blocked and 2.1.248 unclaimed; got 246=[$out246] 248=[$out248]"
    fi
fi
rm -f "$md_mut"

# (7) `blocked` is refused by the kill gate, and widening it took nothing off
#     the allowlist. `empty` — the state these panes used to report — is
#     INDETERMINATE and already refused, so this change moves a pane from one
#     refusing state to another. The assertion pins that, because the
#     nightmare direction for any pane-state widening is a state that becomes
#     kill-authorising.
if [[ -f "$_repo_root/monitor/_bookkeeping.sh" ]]; then
    # shellcheck source=../_bookkeeping.sh
    . "$_repo_root/monitor/_bookkeeping.sh"
    if bk_pane_kill_authorized blocked; then
        bad "kill gate" "bk_pane_kill_authorized AUTHORISED a kill on state=blocked"
    elif [[ "${BK_REFUSE_KIND:-}" == "active" ]]; then
        ok "bk_pane_kill_authorized refuses state=blocked as ACTIVE (widening blocked cannot authorise a kill)"
    else
        bad "kill gate" "blocked refused but as '${BK_REFUSE_KIND:-}', want 'active'"
    fi
    if bk_pane_kill_authorized empty; then
        bad "kill gate" "bk_pane_kill_authorized AUTHORISED a kill on state=empty"
    else
        ok "bk_pane_kill_authorized still refuses state=empty (the allowlist is unchanged by this fix)"
    fi
else
    bad "kill gate" "monitor/_bookkeeping.sh missing — the allowlist assertions did not run"
fi

# (7b) your-org/nexus-code#1340 — THE END-TO-END SAFETY PROPERTY, asserted on
#      the CHAIN rather than on the state token.
#
#      Every assertion above this one is about what `pane-state.sh` PRINTS.
#      The property `#1340` is about is what the kill gate then DOES with it:
#      a worker retrying under `/low-priority` is mid-turn with a visibly
#      incrementing attempt counter, it read `state=idle`, and `idle` is on
#      `_BK_KILL_OK_STATES`. Pinning only the classifier would leave the
#      dangerous half — the composition — unasserted, and the composition is
#      where the 2026-06-15 incident lived.
#
#      THE NEGATIVE CONTROL IS THE OTHER HALF AND IS NOT OPTIONAL. "Every
#      throttled pane is refused" is satisfied by a gate that refuses
#      everything, which would wedge the window-cleanup loop instead of
#      retiring live workers — the issue names that as the other way to be
#      wrong. So a genuinely idle pane must still classify `idle` AND still be
#      kill-AUTHORISED, through the same two steps.
if [[ -f "$_repo_root/monitor/_bookkeeping.sh" ]]; then
    _1340_verdict() {   # _1340_verdict <fixture-basename> -> "<state>|<gate>"
        local _st _g
        _st=$(bash "$HELPER" --fixture "$FIX_DIR/$1" 2>/dev/null \
              | sed -n 's/.*state=\([A-Za-z-]*\).*/\1/p')
        if bk_pane_kill_authorized "$_st"; then _g=AUTHORIZED; else _g=refused; fi
        printf '%s|%s' "$_st" "$_g"
    }
    # The capitalised variant is in this loop DELIBERATELY: it is the one the
    # first cut of the detector got wrong, and its whole value is that it is
    # driven to the AUTHORIZER, not just to the classifier.
    for _thr in throttled-low-priority-retry-synthetic.ansi \
                throttled-low-priority-first-attempt-synthetic.ansi \
                throttled-low-priority-capitalised-synthetic.ansi; do
        _v=$(_1340_verdict "$_thr")
        if [[ "$_v" == "busy|refused" ]]; then
            ok "#1340 $_thr -> $_v (a throttled worker is not kill-authorised)"
        else
            bad "kill gate" "#1340 $_thr -> $_v, want busy|refused — a live worker retrying for capacity is kill-authorised"
        fi
    done
    # …and the field carries the extra bit, so an operator reading the board
    # can tell "throttled" from "working" without a second probe.
    # HERESTRING, NOT A PIPE. `grep -q` exits on its first match and SIGPIPEs
    # the producer, so under `pipefail` the pipeline reports 141 — a FALSE
    # FAILURE on the very input that matched. `test-sigpipe-assertion-lint`
    # caught both of this band's first-cut instances.
    _1340_out=$(bash "$HELPER" --fixture "$FIX_DIR/throttled-low-priority-retry-synthetic.ansi" 2>/dev/null)
    if grep -qF 'throttled=1' <<<"$_1340_out"; then
        ok "#1340 the throttled pane carries throttled=1 (a FIELD, not a new state token)"
    else
        bad "kill gate" "#1340 the throttled pane carries no throttled=1 field"
    fi
    _v=$(_1340_verdict idle-empty-synthetic.ansi)
    if [[ "$_v" == "idle|AUTHORIZED" ]]; then
        ok "#1340 NEGATIVE CONTROL idle-empty-synthetic -> $_v (a quiet pane is still retirable)"
    else
        bad "kill gate" "#1340 NEGATIVE CONTROL idle-empty-synthetic -> $_v, want idle|AUTHORIZED — the fix made every quiet pane active, which wedges the cleanup loop"
    fi
    _1340_busy=$(bash "$HELPER" --fixture "$FIX_DIR/busy-encode-win5.ansi" 2>/dev/null)
    if grep -qF 'throttled=1' <<<"$_1340_busy"; then
        bad "kill gate" "#1340 an ORDINARY busy pane was labelled throttled=1 — the detector fires on any spinner"
    else
        ok "#1340 NEGATIVE CONTROL an ordinary busy pane carries no throttled=1"
    fi
fi

# (8) NOTHING AUTO-ANSWERS IT, AND NO ARM FIRES ON A WORKING PANE.
#
#     The first version of this assertion grepped `_unstick.sh` for the string
#     `trust this folder` and called its absence "nothing auto-answers a
#     security prompt". That is a PRESENCE TEST on a literal, not a test of the
#     property — the shape `#885` names on this board: auditing a helper by
#     whether it is *called* cannot tell you what it *says in each arm*. It
#     would pass unchanged if a future arm matched the dialog by some other
#     literal, which is precisely the case it exists to catch.
#
#     Replaced with the property: drive the actual panes through the actual
#     dispatcher and assert it selects NO arm. `_handle_unstick_window` takes
#     its own `tmux capture-pane` — it never reads pane-state's verdict at all —
#     so a fake `tmux` on PATH feeding it a fixture is the honest harness. It
#     prints the matched arm's name, or nothing.
if [[ -f "$_repo_root/monitor/watcher/_unstick.sh" ]]; then
    md_fake=$(mktemp -d)
    for md_case in "blocked-workspace-trust-realmodel.ansi|the LIVE trust dialog" \
                   "busy-dialog-quoted-midrender-synthetic.ansi|a BUSY pane quoting it" \
                   "busy-dialog-quoted-queued-synthetic.ansi|a pane with a message QUEUED"; do
        IFS='|' read -r md_f md_label <<<"$md_case"
        # A `tmux` that answers `capture-pane` with the fixture and ignores the rest.
        {   printf '#!/usr/bin/env bash\n'
            printf 'if [[ "${1:-}" == capture-pane ]]; then\n'
            printf '  sed -E $%s %q\n' "'s/\\x1b\\[[0-9;?]*[a-zA-Z]//g'" "$FIX_DIR/$md_f"
            printf '  exit 0\nfi\nexit 0\n'
        } > "$md_fake/tmux"
        chmod +x "$md_fake/tmux"
        md_arm=$(PATH="$md_fake:$PATH" bash -c '
            set -uo pipefail
            STATE_DIR=$(mktemp -d); UNSTICK_DIR="$STATE_DIR/unstick"
            UNSTICK_LOG="$STATE_DIR/unstick.log"; mkdir -p "$UNSTICK_DIR"
            TARGET=orchestrator; WATCHER_WINDOW=watcher
            . "'"$_repo_root"'/monitor/watcher/_unstick.sh" >/dev/null
            _handle_unstick_window 7
        ' 2>/dev/null)
        if [[ -z "$md_arm" ]]; then
            ok "_unstick.sh selects NO arm for $md_label (nothing auto-answers it, nothing fires on a working pane)"
        else
            bad "unstick $md_f" "want no arm, got '$md_arm' — an arm now acts on this pane"
        fi
    done
    rm -rf "$md_fake"
else
    bad "unstick" "monitor/watcher/_unstick.sh missing — the auto-answer assertion did not run"
fi

# (8b) NON-VACUITY for (8): the harness must be capable of reporting an arm at
#      all. A dispatcher that returns empty because the fake `tmux` broke would
#      make all three assertions above pass while measuring nothing — the
#      silent-zero shape this repo keeps re-finding. Feed it a pane that MUST
#      match (the rate-limit menu) and require the arm to be named.
if [[ -f "$_repo_root/monitor/watcher/_unstick.sh" ]]; then
    md_fake=$(mktemp -d)
    {   printf '#!/usr/bin/env bash\n'
        printf 'if [[ "${1:-}" == capture-pane ]]; then\n'
        printf '  sed -E $%s %q\n' "'s/\\x1b\\[[0-9;?]*[a-zA-Z]//g'" \
            "$FIX_DIR/blocked-ratelimit-synthetic.ansi"
        printf '  exit 0\nfi\nexit 0\n'
    } > "$md_fake/tmux"
    chmod +x "$md_fake/tmux"
    md_arm=$(PATH="$md_fake:$PATH" bash -c '
        set -uo pipefail
        STATE_DIR=$(mktemp -d); UNSTICK_DIR="$STATE_DIR/unstick"
        UNSTICK_LOG="$STATE_DIR/unstick.log"; mkdir -p "$UNSTICK_DIR"
        TARGET=orchestrator; WATCHER_WINDOW=watcher
        . "'"$_repo_root"'/monitor/watcher/_unstick.sh" >/dev/null
        _handle_unstick_window 7
    ' 2>/dev/null)
    if [[ "$md_arm" == "ratelimit" ]]; then
        ok "the same harness DOES report an arm for the rate-limit menu — (8)'s silence is a measurement, not a broken probe"
    else
        bad "unstick non-vacuity" "the rate-limit fixture should select 'ratelimit', got '$md_arm' — (8) above is vacuous"
    fi
    rm -rf "$md_fake"
fi

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    echo "FAIL"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
