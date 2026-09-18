#!/usr/bin/env bash
# test-entry-signals.sh — drive monitor/watcher/_entry_signals.sh, the helper
# that lets a signal suite survive being launched with SIGINT already IGNORED
# (your-org/nexus-code#1445).
#
# THE DEFECT, measured: `test-startup-window-signal.sh`'s INT case read
# `watcher STILL RUNNING after the startup-window signal` 3 of 3 runs when the
# suite was launched through `monitor/async-run.sh` (setsid … &), and 0 of 3 in
# the foreground of the same shell at the same load. Inside the launcher,
# `trap -p INT` prints `trap -- '' SIGINT`: a non-interactive shell starting an
# async command with job control OFF ignores SIGINT for it, every descendant
# inherits the ignore, and bash cannot `trap` a signal that was ignored at
# entry. main.sh's INT handler therefore never installed and the signal was
# dropped. The TERM arm stayed green in the same runs — `&` never ignores
# SIGTERM — which is the fingerprint that separates this from load.
#
# WHAT IS PINNED:
#   A  CONTROL       — a script with an INT trap, run in the FOREGROUND,
#                      exits 130 when signalled during a foreground child.
#   B  POTENCY       — the SAME script WITHOUT the helper, launched through an
#                      ignoring parent (`cmd &` under job control OFF, the
#                      launcher's shape), runs to completion at rc 0: the
#                      signal is DROPPED. This is the pre-fix behaviour and the
#                      arm that proves the ignoring parent is real.
#   C  REMEDY        — the same script WITH the helper, same ignoring parent,
#                      exits 130: the re-exec restored the disposition.
#   D  LOOP GUARD    — with the restored-marker already set and SIGINT still
#                      ignored, the helper exits 96 LOUDLY rather than
#                      re-exec'ing forever.
#   E  WIRING        — the motivating suite sources the helper and calls it
#                      before anything else, so the fix is attached to the
#                      suite that measured the defect.
#
# CONTAINMENT: every launched arm is bounded by `timeout` on its PARENT and
# its fixture sleeps at most 2 s, so a regression costs seconds and a red,
# never a hang.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
HELPER="$REPO_ROOT/monitor/watcher/_entry_signals.sh"
MOTIVATING="$REPO_ROOT/monitor/watcher/test-startup-window-signal.sh"

# ── this suite DECLARES its own population (the --population protocol) ──────
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        monitor/watcher/_entry_signals.sh \
        monitor/watcher/test-startup-window-signal.sh \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"

WORK=$(mktemp -d -t nexus-entry-signals-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# The fixture: an INT trap, then a foreground child the signal lands during.
# `$0` is what the helper re-execs, so the fixture must be a real file.
cat > "$WORK/fx-plain.sh" <<'FX'
#!/usr/bin/env bash
trap 'exit 130' INT
kill -INT "$$" &      # the signal, from a child, lands during the sleep below
sleep 2
exit 0
FX
{
    printf '#!/usr/bin/env bash\n'
    printf 'source %q\n' "$HELPER"
    printf 'entry_signals_restore_or_exec "$0" "$@"\n'
    tail -n +2 "$WORK/fx-plain.sh"
} > "$WORK/fx-helper.sh"
chmod +x "$WORK/fx-plain.sh" "$WORK/fx-helper.sh"

# An IGNORING PARENT of the launcher's shape: a non-interactive bash with no
# tty on stdin, starting its command async with job control off. `wait`
# forwards the child's status. The `timeout` bound sits on the PARENT, never
# between it and the child: coreutils `timeout` hands its child a DEFAULT
# SIGINT, so `parent → timeout → child` would quietly un-ignore the very
# disposition this arm exists to plant (measured while writing this suite).
ignoring_parent() { timeout 15 bash -c 'exec 0</dev/null; "$@" & wait $!' _ "$@"; }

echo "=== A: control — foreground, the trap fires ==="
timeout 10 bash "$WORK/fx-plain.sh"; rc=$?
assert_eq "foreground: INT trap ran (rc 130)" "$rc" "130"

echo "=== B: potency — ignoring parent, NO helper: the signal is DROPPED ==="
ignoring_parent bash "$WORK/fx-plain.sh"; rc=$?
assert_eq "ignoring parent, no helper: script ran to completion (rc 0) — the pre-fix red" "$rc" "0"
# The parent really did hand the child an ignored SIGINT.
disp=$(ignoring_parent bash -c 'trap -p INT')
assert_contains "ignoring parent hands the child an ignored SIGINT" "$disp" "trap -- '' SIGINT"

echo "=== C: remedy — ignoring parent, WITH helper: restored, the trap fires ==="
ignoring_parent bash "$WORK/fx-helper.sh"; rc=$?
assert_eq "ignoring parent, helper: INT trap ran (rc 130)" "$rc" "130"
# And the restored process really sees a default disposition.
{
    printf '#!/usr/bin/env bash\n'
    printf 'source %q\n' "$HELPER"
    printf 'entry_signals_restore_or_exec "$0" "$@"\n'
    printf 'trap -p INT; echo restored-probe\n'
} > "$WORK/fx-probe.sh"
disp=$(ignoring_parent bash "$WORK/fx-probe.sh")
assert_not_contains "after the re-exec SIGINT is no longer ignored" "$disp" "trap -- '' SIGINT"
assert_contains     "the re-exec'd script reached its body" "$disp" "restored-probe"

echo "=== D: loop guard — restore marker set, SIGINT still ignored: exit 96, LOUD ==="
err=$(ignoring_parent env NEXUS_ENTRY_SIGNALS_RESTORED=1 bash "$WORK/fx-helper.sh" 2>&1 >/dev/null); rc=$?
assert_eq "loop guard exits 96 instead of re-exec'ing forever" "$rc" "96"
assert_contains "loop guard names the issue and the refusal" "$err" "STILL ignored"

echo "=== E: wiring — the motivating suite calls the helper first ==="
assert_eq "test-startup-window-signal.sh sources _entry_signals.sh" \
    "$(grep -oF '/_entry_signals.sh"' "$MOTIVATING" | wc -l | tr -d ' ')" "1"
assert_eq "…and calls entry_signals_restore_or_exec \"\$0\" \"\$@\"" \
    "$(grep -oF 'entry_signals_restore_or_exec "$0" "$@"' "$MOTIVATING" | wc -l | tr -d ' ')" "1"
# The call must precede the first background job the suite starts.
# awk over the FILE rather than `grep | head` / `grep -m1` over a PIPE: no
# reader can close a writer's pipe early (early-exit-readers manifest, #622).
call_line=$(awk 'index($0, "entry_signals_restore_or_exec \"$0\" \"$@\"") { print NR; exit }' "$MOTIVATING")
first_bg=$(awk '/&$/ && $0 !~ /^[[:space:]]*#/ { print NR; exit }' "$MOTIVATING")
assert_eq "the restore runs before the suite's first background job" \
    "$( (( call_line < first_bg )) && echo yes || echo "NO ($call_line vs $first_bg)" )" "yes"

EXPECTED_ASSERTIONS=11
th_summary_and_exit
