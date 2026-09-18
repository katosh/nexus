#!/usr/bin/env bash
# your-org/nexus-code#646 regression: `ng` must REFUSE to start when its
# tmux-targeting helper cannot supply `resolve_window_id` — never launder that
# into "the window is not in tmux".
#
# Run: bash monitor/watcher/test-ng-tmux-helper-runnable.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT
# ----------
# `cmd_retire_window` resolved the window id by EXECUTING the helper:
#
#     wid=$("$_script_dir/_tmux-window.sh" id "$window" 2>/dev/null) || wid=""
#
# `_tmux-window.sh` is mode 100644, so the exec failed rc 126, the diagnostic
# went to /dev/null, and `|| wid=""` converted "I could not run the resolver"
# into a value that ALREADY MEANS something else — "no such window" — with its
# own code path. `ng retire-window` then took the not-present branch: preflight
# SKIPPED, kill SKIPPED, every state surface pruned anyway, success reported,
# for a window that was still alive. The other three callers source the helper,
# which is why only `ng` was affected.
#
# WHY THE TEST IS SHAPED THIS WAY
# -------------------------------
# The tempting assertion — "retire-window resolves a window id" — is a proxy: it
# passes on a tree where the helper happens to work, which is every tree anyone
# runs it on, and says nothing about the failure mode. The property is the
# REFUSAL: when the resolver cannot be obtained, the verb must not run at all.
# So each case below BREAKS the helper deliberately and asserts `ng` exits
# non-zero with a diagnostic naming the cause.
#
# Test 3 is the one that closes the CLASS rather than the instance. A helper
# that sources cleanly but no longer defines the function leaves
# `resolve_window_id` as an unknown command — rc 127, swallowed by the identical
# `|| wid=""` — which is the same defect wearing a different exit code. A fix
# that only checked file existence would pass Tests 1-2 and fail here.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"
MON="$_test_dir/.."

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
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
FAKE="$WORK/nexus"
mkdir -p "$FAKE/monitor" "$FAKE/config" "$FAKE/reports"

build_tree() {  # build_tree — fresh fake nexus with a WORKING helper
    rm -rf "$FAKE/monitor" "$FAKE/config"
    # `.state` must exist: retire-window prunes every state surface and dies with
    # "state dir not usable" without it, which would fail the positive cases for
    # a reason unrelated to the helper.
    mkdir -p "$FAKE/monitor/.state" "$FAKE/config" "$FAKE/reports"
    cp "$NG_REAL" "$FAKE/monitor/ng"
    cp "$MON/_bookkeeping.sh" "$FAKE/monitor/_bookkeeping.sh"
    # your-org/nexus-code#1077: `ng` also refuses without the primary-root resolver.
    cp "$MON/_nexus-root.sh" "$FAKE/monitor/_nexus-root.sh"
    cp "$MON/_tmux-window.sh" "$FAKE/monitor/_tmux-window.sh"
    # your-org/nexus-code#977 — `retire-window` is gate-then-prune, and since
    # #977 the gate runs on the ABSENT path too (checks 1b/1c are obligation
    # checks, not liveness checks). So `retire-preflight.sh` is a hard
    # dependency of every non-`--dry-run` invocation, not of the
    # present-window arm only, and `ng` now refuses BY NAME rather than
    # leaking `rc 127` when it is missing.
    #
    # This fixture omitted it, and that was invisible until #977: the absent
    # path never consulted the gate, so a fake tree with NO GATE AT ALL retired
    # windows and reported success. The subject of this suite is the
    # `_tmux-window.sh` dependency, so supplying the OTHER dependency is what
    # keeps its assertions about the one it means to test.
    cp "$MON/retire-preflight.sh" "$FAKE/monitor/retire-preflight.sh"
    cp "$MON/_obligations.sh"     "$FAKE/monitor/_obligations.sh"
    chmod +x "$FAKE/monitor/retire-preflight.sh"
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
}

run_ng() {  # run_ng <args...> — prints "rc<TAB>output"
    local out rc=0
    out=$(NEXUS_ROOT="$FAKE" NEXUS_WORKER_WINDOW="" \
          bash "$FAKE/monitor/ng" "$@" 2>&1) || rc=$?
    printf '%s\t%s' "$rc" "$out"
}

# ---- Test 1: the baseline — a healthy tree starts -----------------------
#
# Without this, Tests 2 and 3 are worthless: an `ng` that refused to start for
# ANY reason would pass them both. This pins that the refusals below are caused
# by the broken helper and nothing else.

# NOT `--dry-run`: that branch returns BEFORE the window-id resolution, so it
# never reaches the guard under test. Using it here would make Tests 2-3 pass
# for the wrong reason — which is exactly what happened while this suite was
# being written, masked by an earlier (over-broad) startup guard.
echo '=== baseline: ng starts on a tree with a working helper ==='
build_tree
# `--assume-absent`: these two cases must COMPLETE, and completion must not
# depend on whether the environment happens to have a live tmux server. CI
# installs tmux but starts no server, so `list-windows` fails and the resolver
# correctly reports rc 3 "could not look" (your-org/nexus-code#699), which
# retire-window refuses by design. The flag asserts what is true in this
# fixture — window zz-no-such-window-646 does not exist anywhere — without
# weakening the guard under test: with a live server the resolver returns rc 1
# and the flag is never consulted. Tests 2/3 below deliberately do NOT pass it;
# they assert refusals that fire earlier, at ng startup.
res=$(run_ng retire-window zz-no-such-window-646 --assume-absent)
rc=${res%%$'\t'*}; out=${res#*$'\t'}
# Assert the verb actually RAN (it reached dry-run reporting), not merely that
# some refusal string is absent — absence-of-a-string passes for any number of
# unrelated failures.
assert_contains "healthy tree: retire-window runs to completion" "$out" "retired"

# ---- Test 2: helper file absent → REFUSE --------------------------------

echo '=== helper missing → ng refuses to start ==='
build_tree
rm -f "$FAKE/monitor/_tmux-window.sh"
res=$(run_ng retire-window zz-no-such-window-646)
rc=${res%%$'\t'*}; out=${res#*$'\t'}
assert_eq "missing helper: non-zero exit" \
          "$([[ "$rc" -ne 0 ]] && echo nonzero || echo "zero($rc)")" "nonzero"
assert_contains "missing helper: says so on stderr" "$out" "_tmux-window.sh missing or unreadable"

# ---- Test 3: helper sources cleanly but defines nothing → REFUSE --------
#
# CLASS CLOSER. rc 127 instead of rc 126, swallowed by the same `|| wid=""`.
# A fix that only checked for the FILE would pass Tests 1-2 and fail here —
# which is precisely why the file check alone is not the fix.

echo '=== helper defines no resolve_window_id → ng refuses to start ==='
build_tree
printf '#!/usr/bin/env bash\n# valid bash, defines nothing\n:\n' > "$FAKE/monitor/_tmux-window.sh"
res=$(run_ng retire-window zz-no-such-window-646)
rc=${res%%$'\t'*}; out=${res#*$'\t'}
assert_eq "gutted helper: non-zero exit" \
          "$([[ "$rc" -ne 0 ]] && echo nonzero || echo "zero($rc)")" "nonzero"
assert_contains "gutted helper: names the missing function" "$out" "did not define resolve_window_id"
assert_contains "gutted helper: explains the laundering hazard" "$out" "window not found"

# ---- Test 4: the mode that caused it is no longer load-bearing ----------
#
# The shipped helper is mode 100644 and the fix must not quietly depend on that
# changing. Strip every execute bit and require `ng` to work anyway — sourcing
# needs read, not execute. If someone "fixes" #646 with `chmod +x` instead, this
# goes red, which is the intent: a file mode is one checkout on a fork away from
# regressing, silently.

echo '=== helper non-executable (as shipped) → ng still works ==='
build_tree
chmod a-x "$FAKE/monitor/_tmux-window.sh"
res=$(run_ng retire-window zz-no-such-window-646 --assume-absent)
rc=${res%%$'\t'*}; out=${res#*$'\t'}
assert_contains "non-executable helper: retire-window still completes" "$out" "retired"

# ---- Test 5: an UNRELATED verb must not care about this helper ----------
#
# This assertion exists because the first version of this fix broke exactly
# here. Sourcing the helper at `ng` STARTUP made every verb refuse on a tree
# without it — and `ng`'s own fixtures build a fake tree holding only `ng` and
# `_bookkeeping.sh`, so 20 of 30 ng suites went red and all five CI unit cells
# failed. Scoping a precondition wider than its consumer converts an absent
# optional file into a total outage: a worse failure than the one being fixed,
# and the same shape (a guard whose blast radius nobody bounded).
#
# `_tmux-window.sh` is a dependency of retire-window, not of `ng`. This pins
# that distinction so it cannot be re-broken by a future "tidy the sources to
# the top" refactor.

echo '=== helper missing → an unrelated verb still works ==='
build_tree
rm -f "$FAKE/monitor/_tmux-window.sh"
mkdir -p "$FAKE/reports"
printf -- '---\nproject: p\n---\n\n# t\n' > "$FAKE/reports/p_2026-07-30_000000_t.md"
res=$(run_ng report-check "$FAKE/reports/p_2026-07-30_000000_t.md")
rc=${res%%$'\t'*}; out=${res#*$'\t'}
# The property is that report-check REACHED ITS OWN LOGIC — not that it passed.
# It legitimately exits non-zero on an incomplete report; what must never happen
# is `ng` refusing to start because a helper only retire-window needs is absent.
assert_contains "unrelated verb ran its own logic without the helper" "$out" "report-check:"
assert_not_contains "unrelated verb did NOT refuse over the missing helper" "$out" "_tmux-window.sh"

# ---- summary ------------------------------------------------------------
#
# Expected-count guard: an assert_* that never runs reports 0 failures and reads
# as a pass, which is the defect class this whole suite is about.
EXPECTED=9
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
