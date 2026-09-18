# shellcheck shell=bash
# monitor/watcher/_orphan_async.sh — watcher-owned wake loop for workers
# stalled on `idle-orphan-async` (your-org/nexus-code#1071).
#
# ── WHY A WATCHER-OWNED LOOP ────────────────────────────────────────────
#
# On 2026-08-26, six workers across four windows, three clones and two repos
# ended a turn holding external waits whose jobs had already ended. Every
# control fired and none closed the loop:
#
#   1. the worker floor states the ownership rule and is auto-injected;
#   2. `hooks/async-launch-detect.sh` re-injects it at the launch;
#   3. the watcher detects the stall precisely, NAMING the exact wait ids.
#
# All three are ADVISORY. Detection produces a row addressed to an
# orchestrator, and a worker whose row nobody reads waits forever. The fourth
# instance landed TEN MINUTES after the issue was filed, in a worker whose
# prompt carried the injected rule — so "tell the worker harder" is the remedy
# that has already failed six times. This file is the terminal half: the same
# treatment `over-limit` already gets (`_over_limit.sh`, issue #87), which is
# why this deliberately mirrors that file's shape rather than inventing one.
#
# ── WHAT IT WILL NOT DO, AND WHY THAT IS THE DESIGN ─────────────────────
#
# **It never clears a wait. Resume is the default and clearing is the
# exception.** The stall emit currently offers `declare-no-wait.sh` as a
# co-equal option, and that is dangerous in exactly one direction: clearing a
# wait on a job that IS RUNNING destroys the only record that work is
# outstanding. Nothing here calls `declare-no-wait.sh`; the composed brief
# names it only after telling the worker to resume, and only with the
# precondition (independent confirmation the job is not running) attached.
#
# **It never wakes a worker whose job is still running.** THE NEGATIVE
# CONTROL: every wait is resolved before any delivery, and a single `running`
# verdict suppresses the wake entirely. A self-healer that reaps live work is
# strictly worse than the stall it replaces. `idle-orphan-async` means "this
# worker has no resume mechanism" — it does NOT mean "the job is over", and
# conflating the two is how this becomes harmful.
#
# **It never delivers into a pane with input already queued.** `#1065`'s
# delivery contract exists for the duplicate-delivery hazard; a self-healing
# loop that double-delivers is worse than the stall. The wake path re-probes
# and refuses on `queued=1`, and refuses again if the pane no longer reads
# `idle-orphan-async` (it recovered on its own, or an orchestrator got there
# first).
#
# ── THE THREE KINDS OF WAIT, AND WHY THE RESOLVER IS PER-KIND ───────────
#
# The six field instances split three ways, and the split is the design input:
#
#   real Slurm id (`slurm:2219913`)  `sacct` retained `COMPLETED … 0:0`
#                                    → the worker can TRUST its outputs
#   `asyncrun:ar-…`                  `monitor/async-run.sh` retained the rc,
#                                    and distinguishes `died` (killed before
#                                    it could report) from `terminal`
#   `nohup:syn-…` / `slurm:syn-…`    NOTHING was retained. Unresolvable, and
#                                    the brief must SAY SO rather than imply
#                                    the job finished.
#
# **An absent process is not a completed job.** A producer killed mid-write
# leaves a TRUNCATED, PLAUSIBLE intermediate — not an empty one — so it passes
# every emptiness check and silently shortens every number downstream. The
# `unresolvable` verdict is therefore reported as unresolvable, never rounded
# to "finished". That honesty is the only thing that makes the wake safe: a
# wake that says "your job finished" about a job whose status was destroyed
# would launder an OOM into a green light.
#
# ── STATE ───────────────────────────────────────────────────────────────
#
# `monitor/.state/orphan-async-state.tsv`, one row per stalled window, atomic
# rewrite by rename. FIVE tab-separated fields, and it must stay five:
#
#   <window> <waits-csv> <first_seen_epoch> <next_attempt_epoch> <attempts>
#
# `<waits-csv>` is `kind:id,kind:id,…` exactly as `pane-state.sh` emits it in
# `orphan_kinds=`. A post-wake cooldown lives in a SIDECAR directory
# (`orphan-async-woken/<enc-window>`), not a sixth column, for the reason
# `_over_limit.sh` puts its observation epoch in a sidecar: a row file whose
# arity is asserted elsewhere must not grow a column.
#
# ── INJECTED SEAMS (tests replace these) ────────────────────────────────
#   _ORPHAN_ASYNC_LOG_FN      log line sink               (default: noop)
#   _ORPHAN_ASYNC_PASTE_FN    <window> <body-file>        (default: noop, rc 0)
#   _ORPHAN_ASYNC_PROBE_FN    <window-key> -> pane-state line; its EXIT
#                             STATUS is pane-state.sh's own (3 = not a live
#                             window, a positive absence claim; other non-zero
#                             = could not look). A global cannot carry it: the
#                             seam is called in a command substitution.
#   _ORPHAN_ASYNC_RESOLVE_FN  <kind> <id> <window> -> <class>|<detail>
#
# ── ENV KNOBS ───────────────────────────────────────────────────────────
#   MONITOR_ORPHAN_ASYNC_ENABLED             (default 1)
#   MONITOR_ORPHAN_ASYNC_GRACE_SECONDS       (default 300)
#       How long a window must READ `idle-orphan-async` before the watcher
#       intervenes. The worker owns its own wake first; this is a backstop,
#       not a race against the worker's own poller.
#   MONITOR_ORPHAN_ASYNC_RETRY_SECONDS       (default 120)
#       Re-check cadence while at least one wait is still `running`.
#   MONITOR_ORPHAN_ASYNC_COOLDOWN_SECONDS    (default 1800)
#       After a wake, the same window is not woken again for this long. Bounds
#       the nag if a worker idles straight back into the same state.
#   MONITOR_ORPHAN_ASYNC_MAX_HOLD_SECONDS    (default 86400)
#       Absolute per-row ceiling; a row older than this is dropped and logged.
#       Unlike over-limit, holding a row here suppresses nothing, so the
#       ceiling exists only to bound state growth.

# ---- seams ----------------------------------------------------------------

_orphan_async_log_noop()   { return 0; }
_orphan_async_paste_noop() { return 0; }
_ORPHAN_ASYNC_LOG_FN="${_ORPHAN_ASYNC_LOG_FN:-_orphan_async_log_noop}"
_ORPHAN_ASYNC_PASTE_FN="${_ORPHAN_ASYNC_PASTE_FN:-_orphan_async_paste_noop}"
_ORPHAN_ASYNC_PROBE_FN="${_ORPHAN_ASYNC_PROBE_FN:-_orphan_async_probe_pane}"
_ORPHAN_ASYNC_RESOLVE_FN="${_ORPHAN_ASYNC_RESOLVE_FN:-_orphan_async_resolve}"

# ---- the two seams #1101 and the wait-reap add ----------------------------
#
#   _ORPHAN_ASYNC_LOGEVENT_FN  <event> <extra…>   action-log writer
#   _ORPHAN_ASYNC_REAP_FN      <window> <kind> <id>  remove one declared wait
#
# Both default to the real thing and are replaced wholesale by the suite, for
# the reason the existing seams exist: neither may run against live state from
# a fixture.
_orphan_async_logevent_real() {   # <event> <extra…>
    local ng=""
    if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/ng" ]]; then
        ng="$NEXUS_ROOT/monitor/ng"
    elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../ng" ]]; then
        ng=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ng
    else
        return 0
    fi
    local event="$1"; shift
    local -a extra=()
    local e
    for e in "$@"; do extra+=(--extra "$e"); done
    "$ng" log-action watcher --event "$event" "${extra[@]+"${extra[@]}"}" \
        >/dev/null 2>&1 || true
    return 0
}

# ONE WAIT AT A TIME, THROUGH `declare-wait.sh --remove` — not a jq rewrite
# here (your-org/nexus-code#1101 companion finding).
#
# WHO CLEARS, AND WHY IT IS NOT THE RUNNER. The obvious home for this is
# `async-run.sh`: the runner knows the instant it writes a status, and removing
# the wait there is local and atomic-looking. It is not. `declare-wait.sh`'s
# `write_atomic` is a read-modify-write — read the heartbeat, `jq` it, write
# `<file>.$$.tmp`, rename — with NO lock. N runners finishing in the same
# second each compute their removal from a snapshot taken before the others
# wrote, and the last rename wins: N-1 removals vanish, silently, leaving
# exactly the residue this is meant to clear. `procmatch` held EIGHT runs; that
# is the ordinary case, not a corner. A fix whose failure mode is "the wait
# quietly survives" is the defect with extra steps.
#
# The watcher's pass has neither problem: it is single-threaded per cycle, so
# its own removals are sequential, and it runs only against a window reading
# `idle-orphan-async` — an IDLE pane, so `hooks/async-launch-detect.sh` (a
# PostToolUse hook) is not concurrently ADDING one either. The classification
# it needs already lives here and nowhere else.
#
# The MUTATION still goes through `declare-wait.sh`, so the heartbeat format
# keeps one owner and the watcher never writes a file it does not own.
_orphan_async_reap_real() {   # <window> <kind> <id>
    local script=""
    if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/declare-wait.sh" ]]; then
        script="$NEXUS_ROOT/monitor/declare-wait.sh"
    elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../declare-wait.sh" ]]; then
        script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/declare-wait.sh
    else
        return 1
    fi
    NEXUS_WORKER_WINDOW="$1" "$script" --remove "$2" "$3" >/dev/null 2>&1
    local rc=$?
    # rc 4 is `--remove` reporting that it MATCHED NOTHING
    # (your-org/nexus-code#1326). For this caller that is SUCCESS, not
    # failure: the reaper's post-condition is "the wait is no longer in
    # `external_waits`", and an absent wait satisfies it. The wait can
    # legitimately be gone already — the worker removed it itself, or a
    # prior cycle did.
    #
    # Treating it as failure would make the caller at :876 log
    # "could not reap … it will re-flag" about a wait that is gone and
    # will not re-flag — a false diagnostic in a durable log, produced
    # by a status change in a script one directory over. That is the
    # `#1326` change's only behavioural reach into the watcher, and it
    # is handled here rather than by suppressing the new status,
    # because the status is right and this caller's reading of it was
    # the part that needed to be explicit.
    (( rc == 0 || rc == 4 ))
}
_ORPHAN_ASYNC_LOGEVENT_FN="${_ORPHAN_ASYNC_LOGEVENT_FN:-_orphan_async_logevent_real}"
_ORPHAN_ASYNC_REAP_FN="${_ORPHAN_ASYNC_REAP_FN:-_orphan_async_reap_real}"

_orphan_async_enabled() {
    local v="${MONITOR_ORPHAN_ASYNC_ENABLED:-1}"
    [[ "$v" == "1" || "$v" == "true" ]]
}

_orphan_async_knob() {   # <env-name> <default>
    local v="${!1:-}"
    [[ "$v" =~ ^[0-9]+$ ]] || v="$2"
    printf '%s' "$v"
}

# ---- state ----------------------------------------------------------------

_orphan_async_state_path() { printf '%s/orphan-async-state.tsv' "${STATE_DIR:-.}"; }
_orphan_async_woken_dir()  { printf '%s/orphan-async-woken'     "${STATE_DIR:-.}"; }

# Window keys go through the injective encoder wherever they become a FILENAME
# (your-org/nexus-code#941). Inside the TSV the raw name is kept — it is a
# field, not a path — and window names cannot contain a tab.
_orphan_async_enc() {
    if declare -F wk_encode >/dev/null 2>&1; then wk_encode "$1"; else printf '%s' "${1//\//_}"; fi
}

_orphan_async_load() {   # <window> -> row or empty
    local path; path=$(_orphan_async_state_path)
    [[ -f "$path" ]] || return 0
    awk -F'\t' -v w="$1" '$1 == w {print; exit}' "$path" 2>/dev/null
}

_orphan_async_write_row() {   # <window> <waits> <first_seen> <next_attempt> <attempts>
    local path tmp; path=$(_orphan_async_state_path)
    tmp="$path.$$.tmp"
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
    {
        [[ -f "$path" ]] && awk -F'\t' -v w="$1" '$1 != w' "$path" 2>/dev/null
        printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

_orphan_async_drop() {   # <window>
    local path tmp; path=$(_orphan_async_state_path)
    [[ -f "$path" ]] || return 0
    tmp="$path.$$.tmp"
    awk -F'\t' -v w="$1" '$1 != w' "$path" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    if [[ -s "$tmp" ]]; then mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp"
    else rm -f "$tmp" "$path"; fi
    return 0
}

_orphan_async_windows() {
    local path; path=$(_orphan_async_state_path)
    [[ -f "$path" ]] || return 0
    awk -F'\t' 'NF>0 {print $1}' "$path" 2>/dev/null
}

# Post-wake cooldown. A missing/garbage stamp reads as "not in cooldown" —
# the permissive direction, because failing to wake is the defect this file
# exists to close, and an extra wake costs one paste.
_orphan_async_in_cooldown() {   # <window> <now> -> rc 0 when suppressed
    local f cool stamp
    f="$(_orphan_async_woken_dir)/$(_orphan_async_enc "$1")"
    [[ -f "$f" ]] || return 1
    stamp=$(cat "$f" 2>/dev/null) || stamp=""
    [[ "$stamp" =~ ^[0-9]+$ ]] || return 1
    cool=$(_orphan_async_knob MONITOR_ORPHAN_ASYNC_COOLDOWN_SECONDS 1800)
    (( $2 - stamp < cool ))
}

_orphan_async_mark_woken() {   # <window> <now>
    local dir; dir=$(_orphan_async_woken_dir)
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s\n' "$2" > "$dir/$(_orphan_async_enc "$1")" 2>/dev/null || true
}

# ---- pane probe -----------------------------------------------------------

# Returns the FULL pane-state line (not just `state=`), because this loop
# needs three fields from it: `state`, `orphan_kinds` and `queued`.
#
# THE rc IS KEPT, because an EMPTY line has two readings and only one of them
# is terminal (your-org/nexus-code#1101). `pane-state.sh` exits 3 for "that is
# not a live tmux window" — a POSITIVE claim, distinct from every other
# non-zero, which mean "we could not look". Discarding the rc collapsed the two
# into one silence, and `_orphan_async_evaluate_row` then held a row forever
# for a window that no longer existed: 70 identical `could NOT probe` emits
# over 2h24m for `procmatch`, still climbing when the issue was filed.
#
# IT TRAVELS AS THE SEAM'S EXIT STATUS, NOT AS A GLOBAL, and that is not a
# style choice — the first draft used a global and it silently never
# propagated. The seam is invoked as `line=$(probe …)`, a COMMAND
# SUBSTITUTION, so the probe runs in a SUBSHELL and every variable it sets dies
# with it. The caller then read the value it had itself initialised, the
# terminating branch was unreachable, and the suite's own T1 failed rather than
# passing — which is the only reason this was caught rather than shipped as a
# feature that does nothing. An exit status is the one channel that crosses a
# command substitution.
#
# The seam's rc was previously unused (every path `return 0`), so nothing is
# displaced. `_orphan_async_scan_panes` ignores it and keys on an empty line,
# unchanged. The watcher runs `set -uo pipefail` with no `-e`, so a non-zero
# assignment is not fatal there.
#
#   0    a line was produced (or served from the pane cache)
#   3    pane-state.sh: NOT a live tmux window — a positive absence claim
#   *    could not look (no classifier, tmux refused, bad key, …)
_orphan_async_probe_pane() {   # <window-key> [<expected-name>] -> rc = pane-state's
    local key="$1" expected="${2:-}" line=""
    if declare -F _pane_cache_read >/dev/null 2>&1; then
        line=$(_pane_cache_read "$key" "$expected") || line=""
    fi
    if [[ -z "$line" ]]; then
        local script=""
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/pane-state.sh" ]]; then
            script="$NEXUS_ROOT/monitor/pane-state.sh"
        elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../pane-state.sh" ]]; then
            script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pane-state.sh
        else
            # No classifier reachable at all. NOT an absence claim.
            return 127
        fi
        local rc
        line=$("$script" "$key" 2>/dev/null); rc=$?
        (( rc == 0 )) || return "$rc"
        [[ -n "$line" ]] && declare -F _pane_cache_write >/dev/null 2>&1 \
            && _pane_cache_write "$key" "$line"
    fi
    printf '%s' "$line"
    return 0
}

# ---- the DECLARED wait set, in full ---------------------------------------
#
# THE ROW'S `waits` COLUMN IS A DISPLAY STRING, NOT A LIST, and reading it as
# one is a defect this file inherited (your-org/nexus-code#1101).
# `pane-state.sh:_heartbeat_external_waits_summary` caps `orphan_kinds=` at
# 80 CHARACTERS and appends `…`; `_orphan_async_scan_panes` stores that capped
# value verbatim. Measured on `procmatch`: the heartbeat declared EIGHT
# asyncrun waits (199 chars) and the row held
# `asyncrun:ar-6e6…,asyncrun:ar-800…,asyncrun:ar-7c4…,asyn…` — three full
# tokens and a fragment.
#
# It breaks the loop in BOTH directions, and the second is the dangerous one:
#   * the fragment has no `:`, so it resolves `unresolvable` FOREVER — no
#     all-terminal condition can ever be true for a window with >3 waits, so
#     #1101's terminating conjunction would not have cleared the very window
#     #1101 was filed about;
#   * waits 4..N are INVISIBLE to the negative control. "A single `running`
#     verdict suppresses the wake entirely" is this file's stated safety
#     property, and a still-running job past the cap cannot contribute one. A
#     truncated list can therefore license a wake into live work — the exact
#     thing the header says it must never do.
#
# So the AUTHORITATIVE list is read from the heartbeat, which is where the
# worker's hooks write it and where the summary itself was derived; the row's
# value survives only as the fallback for a heartbeat that cannot be read.
_orphan_async_declared_waits() {   # <window> -> full kind:id,… csv, or empty
    local hb="${STATE_DIR:-.}/heartbeat/$(_orphan_async_enc "$1").json"
    [[ -r "$hb" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local csv
    csv=$(jq -r 'if (.external_waits | type) == "array" then
                     (.external_waits | map("\(.kind):\(.id)") | join(","))
                 else empty end' "$hb" 2>/dev/null) || return 1
    [[ -n "$csv" ]] || return 1
    printf '%s' "$csv"
}

# Does this csv show evidence of having been TRUNCATED? A token with no `:`,
# or one carrying the ellipsis the cap appends. Used as a fail-CLOSED gate:
# a list we cannot vouch for never satisfies a terminating condition, because
# "the waits I can see are all terminal" says nothing about the ones the cap
# removed.
_orphan_async_waits_truncated() {   # <csv> -> rc 0 when truncated
    local csv="$1" tok
    local IFS=,
    for tok in $csv; do
        [[ -n "$tok" ]] || continue
        [[ "$tok" == *"…"* ]] && return 0
        [[ "$tok" == *:* ]] || return 0
    done
    return 1
}

# No `| head -1` here, deliberately (your-org/nexus-code#622 / the early-exit
# reader manifest): a pane-state emit is ONE line, so `sed` yields at most one
# match and the pipe bought nothing — while under `pipefail`, which main.sh
# sets, an early-closing reader can hand the writer EPIPE and invert a status.
# The cheapest fix for an early-exit reader is usually to notice it was never
# needed.
# Exact-key, first-match, on a REAL whitespace boundary (skeptic F5 — CONFIRMED).
# The previous `sed -n "s/.*[[:space:]]\{0,\}$2=…"` permitted a ZERO-WIDTH
# boundary, and `.*` is greedy, so a later token merely ENDING in the field name
# shadowed the real one and the LAST match won:
#     state  on `… state=idle-orphan-async … refined_state=busy` -> busy
#     queued on `… queued=1 tqueued=0`                           -> 0
# Not reachable from the current emit's own field names, but reachable through a
# tmux WINDOW NAME containing a space and `state=`/`queued=` — and the harmful
# direction (pasting into a busy pane) is the one this loop must not have.
# Splitting on whitespace and comparing the key EXACTLY removes the class rather
# than patching the two instances. `break` leaves the for-loop, not awk, so this
# is not an early-exit reader — and the input is a herestring, so there is no
# writer to EPIPE in any case.
_orphan_async_field() {   # <line> <name> -> value or empty
    awk -v k="$2" '{
        for (i = 1; i <= NF; i++) {
            n = index($i, "=")
            if (n > 0 && substr($i, 1, n - 1) == k) { print substr($i, n + 1); break }
        }
    }' <<<"$1"
}

# ---- resolver -------------------------------------------------------------

# The sacct call is its own function purely so a test can replace it without
# replacing the state-mapping logic it feeds — the mapping is the part with
# the interesting failure modes, so it must stay under test.
# Capture-then-slice rather than `sacct … | head -1`, for two reasons that
# point the same way. (1) An early-exit reader can EPIPE the writer, and under
# `pipefail` that inverts a status — the defect the early-exit-reader manifest
# tracks. (2) A pipeline's status is its LAST command's, so `sacct … | head`
# would report `head`'s success and a genuinely failed `sacct` would be
# indistinguishable from a job with no accounting record. Here those two are
# resolved to DIFFERENT verdicts (`unresolvable` either way today, but the rc
# is now available to split them), so reading the wrong status would matter.
_orphan_async_sacct() {   # <jobid> -> "<State>|<ExitCode>" or empty
    command -v sacct >/dev/null 2>&1 || return 0
    local out
    out=$(sacct -X -n -P -o State,ExitCode -j "$1" 2>/dev/null) || return 0
    [[ -n "$out" ]] || return 0
    printf '%s' "${out%%$'\n'*}"
}

# _orphan_async_resolve <kind> <id> <window> -> "<class>|<detail>", rc 0 always.
#
# class ∈ running | terminal | died | unresolvable
#
#   running       positively observed still working. SUPPRESSES the wake.
#   terminal      ended, and the ending is RECORDED (rc / Slurm State+ExitCode /
#                 an async-run cancel marker with the pid gone — `cancelled`
#                 is `settled` by async-run.sh's own _verdict_disposition,
#                 your-org/nexus-code#1333; the detail says which).
#   died          the RECORDED handle is gone and no status was written. The
#                 usual cause is a kill before it could report. Distinct from
#                 `terminal` because the output is presumed truncated; distinct
#                 from `unresolvable` because something WAS retained to look at.
#                 NOT "we know it did not finish cleanly" — that is the claim
#                 this used to make and it is not available: `died` classifies
#                 the RECORDED PID, and a live job can have a recorded pid that
#                 names a corpse (your-org/nexus-code#1237 F1/F9). Measured
#                 `died` through +19s, then `terminal|rc=0` at +22s.
#   unresolvable  nothing was retained. NOT rounded to "finished".
#
# THE DEFAULT ARM IS `unresolvable`, NOT `terminal`. A kind this resolver has
# never heard of must not be reported as finished — that is the fail-safe
# direction, because the expensive error here is telling a worker its data is
# good. It is deliberately NOT `running` either: `running` suppresses the wake
# forever, so an unknown kind would silently re-create the stall this closes.
_orphan_async_resolve() {   # <kind> <id> <window>
    local kind="$1" id="$2" window="$3"

    # A synthetic id is the launcher saying it retained no handle. Checked
    # FIRST, before any per-kind arm, because `slurm:syn-…` is real (a
    # submission LOOP tokenised per CALL) and must not reach the sacct arm,
    # where `sacct -j syn-…` would answer empty and be read as "aged out".
    if [[ "$id" == syn-* ]]; then
        # your-org/nexus-code#1439: the id IS a fingerprint of the command —
        # sha1(command)[0:12], minted by monitor/hooks/async-launch-detect.sh —
        # so an unattributable wait can be traced to the Bash call that made
        # it, across EVERY transcript of the session including in-process
        # subagents', which fire the hook under the parent window. Say so.
        printf 'unresolvable|synthetic id — the launcher retained no handle for this job, so its exit status was never recorded. The id is sha1(command)[0:12]: if this window never ran such a command, an in-process SUBAGENT of it did (its transcript lives beside the parent%ss under ~/.claude/projects/); the heartbeat row%ss `launcher` field names it when the harness supplied one' "'" "'"
        return 0
    fi

    case "$kind" in
        asyncrun)
            local script="" line
            if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/async-run.sh" ]]; then
                script="$NEXUS_ROOT/monitor/async-run.sh"
            elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../async-run.sh" ]]; then
                script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/async-run.sh
            else
                printf 'unresolvable|async-run.sh not found — cannot read the retained status'
                return 0
            fi
            # ASK THE AUTHORITY FOR THE MEANING, NOT JUST THE WORD
            # (your-org/nexus-code#1333). This used to restate `_verdict`'s
            # vocabulary as a four-arm case — running/terminal/died/* — and
            # `_verdict` emits SIX, so `cancelled` (marker on disk, pid gone)
            # and `cancel-requested` (marker on disk, pid ALIVE) both fell to
            # the default arm: a job whose own detail string read "stopped on
            # request … did NOT die unattended" was classed `unresolvable`,
            # and a job still running under a cancel request was not
            # `running`, so it could not suppress the wake. A second
            # hand-written list is how that recurs, so there is no list here:
            # `--disposition-line` returns `<disposition>|<verdict>|<detail>`
            # from ONE definition (`_verdict_disposition`) in one call, and
            # this maps the four DISPOSITIONS — a closed set that does not
            # grow when a verdict is added — onto the resolver's classes.
            # An empty answer (old script, timeout, unreadable state) is
            # `unresolvable`, never `terminal` and never `running`.
            line=$(NEXUS_ASYNC_RUN_WINDOW="$window" NEXUS_WORKER_WINDOW="$window" \
                   "$script" --disposition-line "$id" 2>/dev/null) || line=""
            local _disp="${line%%|*}" _rest="${line#*|}"
            case "$_disp" in
                live)    printf 'running|%s'      "${_rest#*|}" ;;
                settled) printf 'terminal|%s'     "${_rest#*|}" ;;
                gone)    printf 'died|%s'         "${_rest#*|}" ;;
                *)       printf 'unresolvable|%s' "${_rest#*|}" ;;
            esac
            return 0
            ;;
        slurm|slurm-srun-async)
            [[ "$id" =~ ^[0-9][0-9_.+]*$ ]] || {
                printf 'unresolvable|not a Slurm job id'
                return 0
            }
            local out state exit_code
            out=$(_orphan_async_sacct "$id")
            if [[ -z "$out" ]]; then
                printf 'unresolvable|sacct returned nothing for job %s (aged out of accounting, or not this cluster)' "$id"
                return 0
            fi
            state="${out%%|*}"; exit_code="${out#*|}"
            # Slurm appends a reason to some states (`CANCELLED by 1234`), so
            # match on the leading word only.
            case "${state%% *}" in
                PENDING|RUNNING|SUSPENDED|REQUEUED|RESIZING|CONFIGURING|SIGNALING|STAGE_OUT|RESV_DEL_HOLD)
                    printf 'running|%s' "$state" ;;
                COMPLETED)
                    printf 'terminal|COMPLETED %s' "$exit_code" ;;
                FAILED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|DEADLINE|PREEMPTED|CANCELLED|REVOKED|SPECIAL_EXIT)
                    # Slurm RETAINED the status, so this is `terminal`, not
                    # `died` — the worker can act on it. `died` is reserved
                    # for "gone, and nothing recorded why".
                    printf 'terminal|%s %s' "$state" "$exit_code" ;;
                *)
                    printf 'unresolvable|unrecognised Slurm state %s' "$state" ;;
            esac
            return 0
            ;;
        longjob)
            # A longjob-watch spec (your-org/nexus-code#1535). This arm is the
            # BACKSTOP for a session whose dispatcher was never armed or died:
            # the `add` verb declares the wait, nothing removes it until the
            # dispatcher retires the watch, so an unarmed session reads
            # `idle-orphan-async` and lands here. The spool is keyed on the
            # session id the heartbeat records, which the watcher must pass
            # explicitly — it has no CLAUDE_CODE_SESSION_ID of its own.
            local script="" line sid hb
            if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/longjob-watch.sh" ]]; then
                script="$NEXUS_ROOT/monitor/longjob-watch.sh"
            elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../longjob-watch.sh" ]]; then
                script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/longjob-watch.sh
            else
                printf 'unresolvable|longjob-watch.sh not found — cannot probe the watch'"'"'s subject'
                return 0
            fi
            hb="${STATE_DIR:-.}/heartbeat/$(_orphan_async_enc "$window").json"
            sid=""; [[ -r "$hb" ]] && sid=$(jq -r '.session_id // empty' "$hb" 2>/dev/null)
            line=$(NEXUS_LONGJOB_SESSION_ID="$sid" NEXUS_WORKER_WINDOW="$window" NEXUS_STATE_DIR="${STATE_DIR:-}" \
                   "$script" resolve "$id" 2>/dev/null) || line=""
            case "${line%%|*}" in
                running)      printf 'running|%s'      "${line#*|}" ;;
                terminal)     printf 'terminal|%s'     "${line#*|}" ;;
                died)         printf 'died|%s'         "${line#*|}" ;;
                unresolvable) printf 'unresolvable|%s' "${line#*|}" ;;
                *)            printf 'unresolvable|longjob-watch.sh resolve gave no answer for %s' "$id" ;;
            esac
            return 0
            ;;
    esac
    printf 'unresolvable|no resolver for kind %s' "$kind"
    return 0
}

# ---- brief ----------------------------------------------------------------

# Compose the wake brief on stdout. RESUME IS THE DEFAULT and clearing is the
# exception; the ordering of these paragraphs is load-bearing, not cosmetic.
_orphan_async_compose_brief() {   # <window> <idle-seconds> <resolved-lines-file>
    local window="$1" idle="$2" resolved="$3"
    local n_unres n_died
    n_unres=$(awk -F'\t' '$2 == "unresolvable"' "$resolved" 2>/dev/null | wc -l)
    n_died=$(awk  -F'\t' '$2 == "died"'         "$resolved" 2>/dev/null | wc -l)

    printf -- '--- async wait resolved (watcher) ---\n\n'
    printf 'You ended a turn holding external async work and installed no resume\n'
    printf 'mechanism, so nothing would have woken you. You have been idle %ss.\n' "$idle"
    # THE HEADER MUST NOT ASSERT WHAT THE RESOLVER COULD NOT ESTABLISH
    # (skeptic F1 on your-org/nexus-code#1071 — CONFIRMED, and reproduced
    # end-to-end against a producer shown alive at the moment of delivery).
    #
    # This line used to read `NONE of them is still running` unconditionally.
    # Neither `unresolvable` nor `died` entails "not running":
    #   * `unresolvable` means NOTHING WAS RETAINED — the state is UNKNOWN. It
    #     is the verdict for every `syn-` wait, i.e. the ordinary case this
    #     whole issue is about.
    #   * `died` means no status was written; the skeptic measured a SIGKILLed
    #     runner whose grandchild `sleep 60` was still alive afterwards.
    # The wake fires when nothing resolved `running` — which is not the same
    # claim as nothing IS running, and the gap is exactly this change's own
    # thesis (an absent record is not a finished job) inverted in the one
    # artefact a worker actually reads. The measured correction elsewhere in
    # this change — a `nohup` child SURVIVES, reparented to init — makes `syn-`
    # the class MOST likely to still be running.
    #
    # `RESUME YOUR TASK NOW` is deliberately unchanged. Resuming is correct in
    # every case; only the STATUS CLAIM was wrong, and it is a separate
    # sentence. Weakening the claim while keeping the imperative cannot
    # re-create the stall.
    local n_unknown=$(( n_unres + n_died ))
    if (( n_unknown == 0 )); then
        printf 'The watcher resolved your waits; NONE of them is still running:\n\n'
    else
        printf 'The watcher could resolve only some of your waits. %d of them\n' "$n_unknown"
        printf 'CANNOT BE SHOWN TO HAVE STOPPED and MAY STILL BE RUNNING — nothing was\n'
        printf 'retained that could say either way. None of your waits was positively\n'
        printf 'observed running, which is why you are being woken; that is NOT the same\n'
        printf 'claim as none of them running:\n\n'
    fi
    while IFS=$'\t' read -r w class detail; do
        [[ -n "$w" ]] || continue
        printf '  %-28s %-12s %s\n' "$w" "$class" "$detail"
    done < "$resolved"
    printf '\nRESUME YOUR TASK NOW. Your waits have NOT been cleared and must not be\n'
    printf 'cleared on this basis — see the last paragraph.\n'

    if (( n_unres > 0 || n_died > 0 )); then
        printf '\n!! %d of your waits cannot vouch for how the job ENDED.\n' \
            "$(( n_unres + n_died ))"
        printf 'AN ABSENT PROCESS IS NOT A COMPLETED JOB. A producer killed mid-write\n'
        printf '(OOM on a shared node is the common one) leaves a TRUNCATED, PLAUSIBLE\n'
        printf 'intermediate — not an empty one — so it passes every emptiness check and\n'
        printf 'silently shortens every number downstream. Before ANY number derived from\n'
        printf 'that output goes into a report, a comment or an issue, validate it\n'
        printf 'STRUCTURALLY against something you can predict independently: expected row\n'
        printf 'count, expected partition, a checksum, a known total. Non-emptiness is not\n'
        printf 'a check.\n'
        printf '\nNext time, launch with a launcher that RETAINS the exit status:\n'
        printf '    monitor/async-run.sh --desc "<what>" -- <cmd> ...\n'
        printf '    monitor/async-run.sh --status <token>\n'
        printf 'A bare `nohup ... &` does not: the parent shell that would reap the status\n'
        printf 'dies with the Bash tool call and the job is reparented to init, so "finished\n'
        printf 'cleanly" and "SIGKILLed" both read as simply absent. Measured on this host.\n'
    fi

    printf '\nClearing a wait: `monitor/declare-no-wait.sh <kind> <id>` exists, and it is\n'
    printf 'the EXCEPTION, not the co-equal alternative to resuming. Clearing a wait on a\n'
    printf 'job that IS running destroys the only record that work is outstanding. Use it\n'
    printf 'only after you have independently confirmed the job is not running (for Slurm:\n'
    printf 'an empty `squeue` for your own ids, checked by id, not by name).\n'
}

# ---- scan -----------------------------------------------------------------

# Record a row for every worker window currently reading `idle-orphan-async`.
# Idempotent: first_seen is PRESERVED across re-observation, so the grace
# measures how long the stall has lasted, not how long since the last scan.
#
# A window that stops reading `idle-orphan-async` has its row dropped — it
# recovered, or an orchestrator got there first. That is a RECONCILIATION, not
# a wake: nothing is delivered.
_orphan_async_scan_panes() {   # <target-window>
    _orphan_async_enabled || return 0
    declare -F _idle_list_worker_windows >/dev/null 2>&1 || return 0
    local now; now=$(date +%s)
    local name activity window_index line state kinds row first_seen attempts
    local grace; grace=$(_orphan_async_knob MONITOR_ORPHAN_ASYNC_GRACE_SECONDS 300)
    while IFS=$'\t' read -r name activity window_index; do
        [[ -n "$name" ]] || continue
        line=$("$_ORPHAN_ASYNC_PROBE_FN" "${window_index:-$name}" "$name")
        # EMPTY IS "COULD NOT LOOK", NEVER "FINE" (your-org/nexus-code#699 shape).
        # Doing nothing is the safe verdict for both readings, so neither
        # record nor drop.
        [[ -n "$line" ]] || continue
        state=$(_orphan_async_field "$line" state)
        if [[ "$state" != "idle-orphan-async" ]]; then
            [[ -n "$(_orphan_async_load "$name")" ]] && _orphan_async_drop "$name"
            continue
        fi
        kinds=$(_orphan_async_field "$line" orphan_kinds)
        [[ -n "$kinds" ]] || kinds="unknown"
        row=$(_orphan_async_load "$name")
        if [[ -n "$row" ]]; then
            first_seen=$(awk -F'\t' '{print $3}' <<<"$row")
            attempts=$(awk -F'\t'  '{print $5}' <<<"$row")
            [[ "$first_seen" =~ ^[0-9]+$ ]] || first_seen="$now"
            [[ "$attempts"   =~ ^[0-9]+$ ]] || attempts=0
            # Refresh the wait set (a worker can add one while stalled) but
            # keep first_seen and next_attempt: re-observing a stall is not
            # progress through it.
            local next; next=$(awk -F'\t' '{print $4}' <<<"$row")
            [[ "$next" =~ ^[0-9]+$ ]] || next=$(( first_seen + grace ))
            _orphan_async_write_row "$name" "$kinds" "$first_seen" "$next" "$attempts"
        else
            _orphan_async_write_row "$name" "$kinds" "$now" "$(( now + grace ))" 0
        fi
    done < <(_idle_list_worker_windows)
    return 0
}

# ---- wake -----------------------------------------------------------------

# Resolve every wait in <waits-csv> into <resolved-file> (tab-separated:
# `<kind:id>\t<class>\t<detail>`). Prints the number that resolved `running`.
_orphan_async_resolve_all() {   # <waits-csv> <window> <resolved-file>
    local csv="$1" window="$2" out="$3" running=0
    : > "$out"
    local IFS=,
    local w
    for w in $csv; do
        [[ -n "$w" ]] || continue
        local kind="${w%%:*}" id="${w#*:}" verdict class detail
        # A wait with no `:` is malformed; treat it as unresolvable rather
        # than silently splitting it into a kind that resolves to nothing.
        [[ "$w" == *:* ]] || { kind="$w"; id=""; }
        verdict=$("$_ORPHAN_ASYNC_RESOLVE_FN" "$kind" "$id" "$window")
        class="${verdict%%|*}"; detail="${verdict#*|}"
        [[ -n "$class" ]] || { class="unresolvable"; detail="resolver returned nothing"; }
        printf '%s\t%s\t%s\n' "$w" "$class" "$detail" >> "$out"
        [[ "$class" == "running" ]] && running=$(( running + 1 ))
    done
    printf '%s' "$running"
}

# Every resolved wait carries class `terminal`? (>=1 line, and no line of any
# other class.) THE PREDICATE IS `terminal`, NEVER "not running", and that is
# the whole design rather than a detail:
#
#   terminal      the runner WROTE a status; the rc is KNOWN. Safe to act on.
#   died          the pid is gone and NOTHING was written. The output is
#                 presumed TRUNCATED — short, plausible, passing every
#                 emptiness check — which is precisely when a worker most needs
#                 to be told. Auto-clearing it would launder an OOM into a
#                 green light.
#   unresolvable  a synthetic id, an aged-out sacct record, a missing tool. We
#                 do not know, so we do not act.
#   running       live work.
#
# So: CLEAR WHEN THE RUNNER REPORTED, never when the PROCESS VANISHED. #1101
# draws the identical line from the other side (pane-absent alone must not
# clear a row); in both subsystems the wrong predicate is the one that looks
# more obvious.
_orphan_async_all_reported() {   # <resolved-file> -> rc 0 when every wait is `terminal`
    local f="$1" n=0 other=0 cls
    [[ -s "$f" ]] || return 1
    while IFS=$'\t' read -r _ cls _; do
        [[ -n "$cls" ]] || continue
        n=$(( n + 1 ))
        [[ "$cls" == "terminal" ]] || other=$(( other + 1 ))
    done < "$f"
    (( n > 0 && other == 0 ))
}

_orphan_async_evaluate_row() {   # <row> <now>
    local row="$1" now="$2"
    local window waits first_seen next_attempt attempts
    IFS=$'\t' read -r window waits first_seen next_attempt attempts <<<"$row"
    [[ -n "$window" ]] || return 0
    [[ "$first_seen"   =~ ^[0-9]+$ ]] || first_seen="$now"
    [[ "$next_attempt" =~ ^[0-9]+$ ]] || next_attempt="$now"
    [[ "$attempts"     =~ ^[0-9]+$ ]] || attempts=0

    # Absolute ceiling. Bounds state growth only — a held row suppresses
    # nothing here, unlike over-limit — so the action is DROP + log, never a
    # fail-open paste. A still-stalled window is re-recorded by the next scan.
    local max_hold; max_hold=$(_orphan_async_knob MONITOR_ORPHAN_ASYNC_MAX_HOLD_SECONDS 86400)
    if (( now - first_seen > max_hold )); then
        "$_ORPHAN_ASYNC_LOG_FN" \
            "orphan-async: '${window}' exceeded the absolute ceiling (${max_hold}s); dropping the row (a rescan will re-record it if it is still stalled)"
        _orphan_async_drop "$window"
        return 0
    fi

    (( now >= next_attempt )) || return 0

    if _orphan_async_in_cooldown "$window" "$now"; then
        "$_ORPHAN_ASYNC_LOG_FN" "orphan-async: '${window}' woken recently; in cooldown"
        _orphan_async_write_row "$window" "$waits" "$first_seen" \
            "$(( now + $(_orphan_async_knob MONITOR_ORPHAN_ASYNC_RETRY_SECONDS 120) ))" "$attempts"
        return 0
    fi

    # ---- THE AUTHORITATIVE WAIT LIST, not the row's display string --------
    # See `_orphan_async_declared_waits`. The row carries `pane-state.sh`'s
    # 80-CHARACTER-CAPPED `orphan_kinds=` value; the heartbeat carries the set.
    # Falling back to the row keeps a heartbeat-less fixture working, and
    # `truncated` then gates every terminating decision below.
    local full truncated=0
    if full=$(_orphan_async_declared_waits "$window"); then
        waits="$full"
    fi
    _orphan_async_waits_truncated "$waits" && truncated=1

    # ---- resolve BEFORE probing: the negative control is the cheap check ---
    local resolved running
    resolved=$(mktemp) || return 0
    running=$(_orphan_async_resolve_all "$waits" "$window" "$resolved")
    if [[ "$running" =~ ^[1-9][0-9]*$ ]]; then
        # THE NEGATIVE CONTROL. At least one job is positively observed still
        # working, so this worker is waiting for something real. Do NOT wake:
        # a self-healer that reaps live work is worse than the stall.
        "$_ORPHAN_ASYNC_LOG_FN" \
            "orphan-async: '${window}' has ${running} wait(s) STILL RUNNING; not waking"
        _orphan_async_write_row "$window" "$waits" "$first_seen" \
            "$(( now + $(_orphan_async_knob MONITOR_ORPHAN_ASYNC_RETRY_SECONDS 120) ))" "$attempts"
        rm -f "$resolved"
        return 0
    fi

    # ---- delivery gates ---------------------------------------------------
    local line state queued probe_rc
    line=$("$_ORPHAN_ASYNC_PROBE_FN" "$window" "$window"); probe_rc=$?
    if [[ -z "$line" ]]; then
        # ---- THE TERMINATING CONDITION (your-org/nexus-code#1101) ---------
        #
        # The hold below is CORRECT and is not being weakened: "an unobserved
        # pane is not a stalled one" is the same fail-closed reasoning as #603
        # and `bk_pane_kill_authorized`. What it lacked was any way to END when
        # the pane is not merely unobserved but GONE, because `pane-state.sh`'s
        # rc was discarded and both facts arrived as one silence. Measured
        # consequence: `procmatch` — no tmux window, all eight async runs
        # terminal, no `window-close` in the action log — re-emitted this line
        # every ~2 minutes, 70 times over 2h24m and still climbing.
        #
        # THE CONJUNCTION IS LOAD-BEARING. Pane-absent ALONE must never clear a
        # row: a worker whose pane the classifier cannot see while its job runs
        # is exactly what the hold protects, and clearing on absence alone
        # would reintroduce it. All three conjuncts:
        #
        #   1. rc 3 — `pane-state.sh` POSITIVELY established "not a live tmux
        #      window". Every other non-zero means "could not look".
        #   2. every declared wait resolved `terminal` — the runner REPORTED.
        #      `died` and `unresolvable` do NOT qualify; see
        #      `_orphan_async_all_reported`.
        #   3. the wait list is not truncated — a list we cannot vouch for
        #      cannot satisfy a claim about ALL of its members.
        #
        # THE ROW'S DISAPPEARANCE IS ALSO LOGGED, because the absence of a
        # `window-close` event is what made this state unreadable in the first
        # place: `tmux kill-window` removes the pane and `ng log-action …
        # --event window-close` tells the state layer, and nothing couples
        # them, so a crash / a manual kill / any cleanup path that skips the
        # log strands a record forever. A synthetic close with an explicit
        # `reason=pane-vanished-unlogged` records what was inferred and how,
        # rather than letting the row vanish as silently as it appeared.
        #
        # THE WAITS ARE NOT REAPED HERE, deliberately. The window is gone;
        # nothing reads its heartbeat once this row is dropped, and that
        # heartbeat is the durable record of what the window was waiting on
        # when it died. Destroying evidence to tidy state nobody consumes is a
        # cost with no benefit.
        if (( probe_rc == 3 )) && (( truncated == 0 )) \
           && _orphan_async_all_reported "$resolved"; then
            "$_ORPHAN_ASYNC_LOG_FN" \
                "orphan-async: '${window}' is GONE from tmux and every declared wait REPORTED a terminal status — closing the row (reason=pane-vanished-unlogged, waits=${waits})"
            "$_ORPHAN_ASYNC_LOGEVENT_FN" window-close \
                "window=${window}" "reason=pane-vanished-unlogged" \
                "source=orphan-async" "waits=${waits}"
            _orphan_async_drop "$window"
            rm -f "$resolved"
            return 0
        fi
        local _why="an unobserved pane is not a stalled one"
        if (( probe_rc == 3 )); then
            if (( truncated )); then
                _why="the pane is GONE, but the declared wait list is TRUNCATED so 'every wait terminal' cannot be established"
            else
                _why="the pane is GONE, but not every declared wait REPORTED a terminal status (a died/unresolvable wait is not a finished one)"
            fi
        fi
        "$_ORPHAN_ASYNC_LOG_FN" \
            "orphan-async: could NOT probe '${window}' — holding the row; ${_why}"
        _orphan_async_write_row "$window" "$waits" "$first_seen" \
            "$(( now + $(_orphan_async_knob MONITOR_ORPHAN_ASYNC_RETRY_SECONDS 120) ))" "$attempts"
        rm -f "$resolved"
        return 0
    fi
    state=$(_orphan_async_field "$line" state)
    queued=$(_orphan_async_field "$line" queued)

    if [[ "$queued" == "1" ]]; then
        # #1065's duplicate-delivery hazard. Input is ALREADY waiting behind a
        # running turn; pasting now stacks a second copy. Hold the row — the
        # queued message may itself be the resume.
        "$_ORPHAN_ASYNC_LOG_FN" \
            "orphan-async: '${window}' has input QUEUED (queued=1); refusing to deliver"
        _orphan_async_write_row "$window" "$waits" "$first_seen" \
            "$(( now + $(_orphan_async_knob MONITOR_ORPHAN_ASYNC_RETRY_SECONDS 120) ))" "$attempts"
        rm -f "$resolved"
        return 0
    fi

    if [[ "$state" != "idle-orphan-async" ]]; then
        # Recovered on its own, or an orchestrator got there first. Delivering
        # now would be the double-delivery this loop must not cause.
        "$_ORPHAN_ASYNC_LOG_FN" \
            "orphan-async: '${window}' no longer reads idle-orphan-async (state=${state:-?}); dropping the row without delivering"
        _orphan_async_drop "$window"
        rm -f "$resolved"
        return 0
    fi

    # ---- deliver ----------------------------------------------------------
    local body idle
    idle=$(( now - first_seen )); (( idle >= 0 )) || idle=0
    body=$(mktemp) || { rm -f "$resolved"; return 0; }
    _orphan_async_compose_brief "$window" "$idle" "$resolved" > "$body"

    # Stamp the machine-input ledger BEFORE the paste (stamp-before-paste,
    # #293): this is a watcher-initiated wake into a WORKER pane, so the
    # resulting UserPromptSubmit must be attributed to the machine. An
    # unstamped wake leaves machine_epoch stale and falsely marks the window
    # operator-engaged, holding retire-preflight at safe=0.
    declare -F _machine_input_stamp >/dev/null 2>&1 \
        && _machine_input_stamp "$window" "orphan-async-wake"

    if "$_ORPHAN_ASYNC_PASTE_FN" "$window" "$body"; then
        "$_ORPHAN_ASYNC_LOG_FN" \
            "orphan-async: '${window}' woken after ${idle}s (waits=${waits}); resolution brief pasted"
        _orphan_async_mark_woken "$window" "$now"
        _orphan_async_drop "$window"
        # ---- REAP THE REPORTED WAITS, AFTER the worker has been told ------
        #
        # NOTHING removes a declared `external_wait` when its job finishes.
        # `declare-wait.sh --remove` exists but only a worker calling it by
        # hand ever fires it, so the terminating evidence the runner already
        # wrote to disk — `async-run.sh`'s status file, whose whole purpose
        # (#1071) is to keep "finished cleanly" and "gone" distinguishable —
        # is never consumed. Measured 2026-08-28: of 27 declared `asyncrun`
        # waits across 6 live heartbeats, 25 were `terminal`, 1 `running`,
        # 1 `died`. The operational cost is a worker that goes
        # `idle-orphan-async` after doing real work, is resumed, and RE-FLAGS
        # on its next turn because the waits are still declared.
        #
        # AFTER THE PASTE, NOT BEFORE, and the ordering is the point. Reaping
        # first would clear the very signal that produces the wake, so the
        # worker would silently drop out of `idle-orphan-async` and never be
        # told its jobs finished — trading a loud nag for an invisible one.
        # The brief has now named every resolution; the declarations have done
        # their job. A FAILED paste reaps nothing, for the same reason.
        #
        # Only `terminal` waits are reaped (`_orphan_async_all_reported`'s
        # predicate, applied per-wait): a `died` wait keeps flagging until a
        # human rules on a possibly-truncated output, which is the intended
        # cost.
        local _rk _rc_class _rw
        while IFS=$'\t' read -r _rw _rc_class _; do
            [[ "$_rc_class" == "terminal" ]] || continue
            [[ "$_rw" == *:* ]] || continue
            _rk="${_rw%%:*}"
            "$_ORPHAN_ASYNC_REAP_FN" "$window" "$_rk" "${_rw#*:}" \
                || "$_ORPHAN_ASYNC_LOG_FN" \
                    "orphan-async: '${window}' could not reap the reported wait ${_rw} — it will re-flag; remove it with declare-wait.sh --remove ${_rk} ${_rw#*:}"
        done < "$resolved"
    else
        "$_ORPHAN_ASYNC_LOG_FN" \
            "orphan-async: '${window}' paste FAILED; will retry next cycle"
        _orphan_async_write_row "$window" "$waits" "$first_seen" \
            "$(( now + $(_orphan_async_knob MONITOR_ORPHAN_ASYNC_RETRY_SECONDS 120) ))" \
            "$(( attempts + 1 ))"
    fi
    rm -f "$body" "$resolved"
    return 0
}

_orphan_async_process_wakes() {   # <target-window>
    _orphan_async_enabled || return 0
    local path now snapshot row
    path=$(_orphan_async_state_path)
    [[ -f "$path" ]] || return 0
    now=$(date +%s)
    # Snapshot up front so a mid-loop drop/rewrite cannot disturb iteration.
    snapshot=$(cat "$path" 2>/dev/null)
    [[ -n "$snapshot" ]] || return 0
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        _orphan_async_evaluate_row "$row" "$now"
    done <<<"$snapshot"
    return 0
}
