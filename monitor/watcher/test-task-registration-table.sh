#!/usr/bin/env bash
# GOLDEN TABLE for the watcher's production task registrations
# (your-org/nexus-code#568 B4).
#
# THE GAP THIS CLOSES. `test-scheduler-priority-queue.sh` is 736 lines and
# tests the scheduler MECHANISM rigorously — but every task it registers is
# synthetic (`basic`, `fast`/`slow`, `adapt`, `task_a`/`task_b`). A grep for
# `_schedule_task` across all 200+ suite files finds only those dummies. So the
# real catalog — 23 registrations that decide how often the watcher looks at
# GitHub, how fast an operator comment surfaces, and which work runs async —
# was entirely unasserted. Change `github_poll` from 600 s to 60 s, or flip
# `idle_section` from `--class expensive --async` to synchronous, and the whole
# suite stayed green. That made it the largest unprovable-refactor surface in
# the repo: nothing could demonstrate a scheduler change was behaviour-
# preserving, because nothing recorded the behaviour.
#
# THIS TEST IS DELIBERATELY BRITTLE. It is a snapshot, not a validator: any
# edit to the catalog turns it red, and the required golden-table update is the
# review prompt. That is the whole point — a cadence or class change should
# have to be stated, not slipped in. When you change a registration on purpose,
# update the table below in the same commit and say why in the message.
#
# STATIC parse, no execution: main.sh carries top-level state and a scheduler
# loop, so it cannot be sourced. Reading the registration text is also the
# right altitude — what we care about is what the file DECLARES.
#
# Run: bash monitor/watcher/test-task-registration-table.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SH="$_test_dir/main.sh"
CONFIG_SH="$_test_dir/_config.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -r "$MAIN_SH" ]] || { echo "missing $MAIN_SH" >&2; exit 1; }

# ---- extract the catalog --------------------------------------------------
# Join continuation lines, keep only real `_schedule_task` invocations (not the
# prose that mentions them), and normalise runs of whitespace so the golden
# table stays readable and alignment changes are not diffs.
actual=$(
    sed -e ':a' -e '/\\$/{N; s/\\\n//; ta}' "$MAIN_SH" \
    | grep -E '^[[:space:]]*_schedule_task[[:space:]]+[a-z_]+[[:space:]]' \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]+/ /g; s/"//g; s/[[:space:]]*$//'
)

# ---- the golden table -----------------------------------------------------
# Format: `_schedule_task <name> <interval> <fn> --class <c> [--async]`.
# An interval naming a MONITOR_* variable is a config-driven cadence; the
# defaults for those are pinned separately below, so a knob whose default moves
# is caught even though the registration line does not change.
read -r -d '' golden <<'GOLDEN'
_schedule_task auth_hold 5 _v2_task_auth_hold --class cheap
_schedule_task over_limit_wakes 5 _v2_task_over_limit_wakes --class cheap
_schedule_task orphan_async_wakes 15 _v2_task_orphan_async_wakes --class cheap
_schedule_task target_window 2 _v2_task_target_window_probe --class cheap
_schedule_task orchestrator_liveness 5 _v2_task_orchestrator_liveness --class cheap
_schedule_task pending_decisions 10 _v2_task_pending_decisions --class cheap
_schedule_task requests_poll 10 _v2_task_requests_poll --class cheap
_schedule_task bell_windows 30 _v2_task_bell_windows --class cheap
_schedule_task selection_snapshot 10 _v2_task_selection_snapshot --class cheap
_schedule_task prune_archive 600 _v2_task_prune_archive --class cheap
_schedule_task detect_unstick 10 _v2_task_detect_unstick --class medium --async
_schedule_task snapshot_local 30 _v2_task_snapshot_local --class medium --async
_schedule_task idle_section 30 _v2_task_idle_section --class expensive --async
_schedule_task over_limit_scan 60 _v2_task_over_limit_scan --class expensive --async
_schedule_task orphan_async_scan 60 _v2_task_orphan_async_scan --class expensive --async
_schedule_task deliveries_poll 15 _v2_task_deliveries_poll --class medium --async
_schedule_task github_poll 600 _v2_task_github_poll --class expensive --async
_schedule_task full_state_snap 600 _v2_task_full_state_snap --class expensive --async
_schedule_task reports_roll $MONITOR_REPORTS_ROLL_INTERVAL_SECONDS _v2_task_reports_roll --class medium --async
_schedule_task functional_check 600 _v2_task_functional_check --class expensive --async
_schedule_task cc_version_check $MONITOR_CC_UPDATE_INTERVAL_SECONDS _v2_task_cc_version_check --class expensive --async
_schedule_task cc_auto_update $MONITOR_CC_AUTO_UPDATE_CHECK_INTERVAL_SECONDS _v2_task_cc_auto_update --class expensive --async
_schedule_task version_check $MONITOR_VERSION_CHECK_INTERVAL_SECONDS _v2_task_version_check --class medium --async
_schedule_task clone_drift $MONITOR_CLONE_DRIFT_INTERVAL_SECONDS _v2_task_clone_drift --class expensive --async
_schedule_task service_health $MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS _v2_task_service_health --class medium --async
_schedule_task compose_emit $INTERVAL _v2_task_compose_emit --class medium --async
_schedule_task comment_surface $MONITOR_COMMENT_SURFACE_INTERVAL_SECONDS _v2_task_comment_surface --class medium --async
GOLDEN

if [[ "$actual" == "$golden" ]]; then
    ok "task registration table matches the golden snapshot ($(grep -c . <<<"$golden") tasks)"
else
    bad "task registration table CHANGED" "$(printf '\n%s\n' "$(diff <(printf '%s\n' "$golden") <(printf '%s\n' "$actual") || true)")"
    echo "  If the change is intentional, update the golden table in this file" >&2
    echo "  in the SAME commit and say why. That is the review prompt, by design." >&2
fi

# ---- invariants that outlive the exact numbers ----------------------------
# These say WHY the table looks the way it does, so a future edit that keeps
# the table shape but breaks the intent is still caught.

# 22 -> 23: `clone_drift` added by your-org/nexus-code#614. It is the peer of
# `version_check`: that task asks "did the files on disk change", which cannot
# see a pull that never happened, so this one compares HEAD against the LIVE
# remote tip. Registered `expensive --async` because it makes network calls
# (one `git ls-remote`, and a `gh api compare` only when the tip is not already
# local) and expensive work must never hold the synchronous slot. Hourly, from
# `MONITOR_CLONE_DRIFT_INTERVAL_SECONDS` — the condition it catches is measured
# in days, so a tighter cadence would buy nothing and spend rate limit.
n_tasks=$(grep -c . <<<"$actual")
# 23 -> 25: `orphan_async_wakes` and `orphan_async_scan`, added by
# your-org/nexus-code#1071 (abac969) to close the idle-orphan-async loop — a
# worker that goes idle with an async job still in flight. They landed without
# the golden-table update this suite exists to prompt for, which is why `dev`
# has been red here; the pairing mirrors `over_limit_wakes`/`over_limit_scan`
# exactly, and the classes follow the same rule: the WAKES half is cheap and
# synchronous (it only reads due wakes), the SCAN half is expensive --async
# because it probes every worker pane (one pane-state call per window) and
# must never hold the synchronous slot. Verified against the source rather
# than inferred: main.sh:4791/4804 carry those exact classes, and the two
# bodies are one-liners onto _orphan_async_process_wakes and
# _orphan_async_scan_panes respectively.
# 26 since #1518 (w237, bundled by w239): `auth_hold` is the login-hold observer
# — the third arm beside over_limit in the emit ladder, scheduled cheap every 5.
# 27 since your-org/nexus-code#1528 (w240): `selection_snapshot` is the rolling
# last-seen window-selection writer the respawn's rule-4 arm reads (10 s, cheap,
# sync — one `list-windows -a` and one small atomic write per fire).
[[ "$n_tasks" == 27 ]] && ok "27 tasks registered" || bad "task count" "got $n_tasks, want 27"

# Every task must declare a cost class — the scheduler's whole priority model
# reads it, and an unclassified task silently lands in the default bucket.
unclassed=$(grep -v -- '--class ' <<<"$actual" || true)
[[ -z "$unclassed" ]] && ok "every task declares a --class" || bad "missing --class" "$unclassed"

# `expensive` work must never hold the scheduler's synchronous slot: an
# expensive sync task blocks every cheap probe behind it for its whole
# duration, which is the stall shape the async split exists to prevent.
sync_expensive=$(grep -- '--class expensive' <<<"$actual" | grep -v -- '--async' || true)
[[ -z "$sync_expensive" ]] && ok "no expensive task runs synchronously" || bad "expensive+sync" "$sync_expensive"

# The comment path is the latency-critical one (#562): comment_surface exists
# to surface operator comments without waiting on the sweep-priced compose
# body, so its cadence must not be slower than the delivery poll that feeds it.
grep -q '^_schedule_task comment_surface \$MONITOR_COMMENT_SURFACE_INTERVAL_SECONDS ' <<<"$actual" \
    && ok "comment_surface cadence stays config-driven (#562 fast path)" \
    || bad "comment_surface cadence" "no longer driven by MONITOR_COMMENT_SURFACE_INTERVAL_SECONDS"

# target_window is the respawn trigger; at 2 s it is the tightest probe in the
# catalog and must stay cheap+synchronous (an async probe cannot force-fire
# compose_emit on rc=2 — subshell scheduler mutations are lost).
grep -q '^_schedule_task target_window 2 _v2_task_target_window_probe --class cheap$' <<<"$actual" \
    && ok "target_window stays 2s, cheap, SYNCHRONOUS (rc=2 force-fire depends on it)" \
    || bad "target_window registration" "changed — the rc=2 force-fire path depends on it being sync"

# ---- pinned defaults for the config-driven cadences -----------------------
# The registration line for these names a variable, so the table alone would
# not notice a default moving from 15 s to 600 s. Pin the defaults where
# _config.sh resolves them.
check_default() {  # <var> <expected-default>
    local var="$1" want="$2" got
    got=$(grep -oE "^${var}=\"\\\$\{${var}:-\\\$\(\"\\\$_cfg\" [a-z_.]+ ${want}\)\}\"" "$CONFIG_SH" | head -1)
    if [[ -n "$got" ]]; then
        ok "$var default stays $want"
    else
        # Fall back to a looser read so the message names what it actually is.
        local line; line=$(grep -m1 "^${var}=" "$CONFIG_SH" || true)
        bad "$var default" "expected default $want; resolved line: ${line:-<not found>}"
    fi
}
if [[ -r "$CONFIG_SH" ]]; then
    check_default MONITOR_COMMENT_SURFACE_INTERVAL_SECONDS 15
    check_default MONITOR_VERSION_CHECK_INTERVAL_SECONDS 60
    check_default MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS 120
    check_default MONITOR_REPORTS_ROLL_INTERVAL_SECONDS 3600
    check_default MONITOR_CC_UPDATE_INTERVAL_SECONDS 86400
    check_default MONITOR_CC_AUTO_UPDATE_CHECK_INTERVAL_SECONDS 300
else
    bad "config defaults" "$CONFIG_SH unreadable"
fi

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
echo "FAILED" >&2; exit 1
