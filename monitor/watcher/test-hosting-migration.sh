#!/usr/bin/env bash
# Unit tests for the watcher's legacy-hosting detection + one-shot
# migration notice (`monitor/watcher/_hosting_migration.sh`,
# issue 182).
#
# The cutover to headless hosting (your-org/nexus-code#238) is
# self-delivering: when new watcher code starts under legacy hosting
# (window-hosted entry.sh, manual foreground run — anything that is
# not the launcher's `WATCHER_WINDOW=headless` spawn), the startup
# sweep includes a `--- watcher hosting migration ---` section telling
# the orchestrator how to converge, and the watcher keeps working
# normally. The properties this suite pins down:
#
#   - Detection: exactly the launcher's `headless` marker counts as
#     headless; `watcher` (pre-cutover entry.sh), empty/unset, and any
#     other value count as legacy.
#   - Notice content: names the converge command (`svc.sh restart
#     watcher`), the pull-BEFORE-restart ordering, the verification
#     verb (`ng watcher-status` → `hosting: headless`), and the docs
#     page — and says the watcher keeps working normally.
#   - One-shot wiring: main.sh computes the notice ONCE in the startup
#     sweep (no per-cycle recomputation), renders it through
#     compose_report's dedicated 10th section, and the steady-state
#     emit path never passes it — so a legacy watcher is informed once
#     per lifecycle, never nagged per cycle.
#
# The wiring checks are structural (grep against main.sh's source):
# main.sh is not sourceable in isolation, and the seam the assertions
# pin (startup-sweep-only computation, section header, gate inclusion)
# is exactly what a regression would have to touch.
#
# Run: bash monitor/watcher/test-hosting-migration.sh

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_hosting_migration.sh
source "$_script_dir/_hosting_migration.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

# ---- 1-4: detection -------------------------------------------------------

if _hosting_is_legacy "watcher"; then
    pass "WATCHER_WINDOW=watcher (pre-cutover entry.sh) → legacy"
else
    fail "WATCHER_WINDOW=watcher should be legacy"
fi

if _hosting_is_legacy ""; then
    pass "WATCHER_WINDOW unset/empty (manual foreground run) → legacy"
else
    fail "empty WATCHER_WINDOW should be legacy"
fi

if _hosting_is_legacy "some-window"; then
    pass "arbitrary window name → legacy"
else
    fail "arbitrary window name should be legacy"
fi

if ! _hosting_is_legacy "headless"; then
    pass "WATCHER_WINDOW=headless (launcher contract) → NOT legacy"
else
    fail "headless must not be classified legacy"
fi

# ---- 5-7: notice content --------------------------------------------------

NOTICE=$(_hosting_render_migration_notice "/some/nexus/root" "watcher")
# Whitespace-normalized copy so assertions survive line wrapping.
NOTICE_FLAT=$(tr -s ' \n' ' ' <<<"$NOTICE")

if [[ "$NOTICE" == *"/some/nexus/root/monitor/svc.sh restart watcher"* ]] \
   && [[ "$NOTICE_FLAT" == *"sweeps the legacy 'watcher' window automatically"* ]]; then
    pass "notice names the converge command rooted at the given nexus root + the automatic window sweep"
else
    fail "notice missing converge command / sweep note: $NOTICE"
fi

if [[ "$NOTICE" == *"pull BEFORE restart"* ]] \
   && [[ "$NOTICE" == *"git -C /some/nexus/root pull"* ]] \
   && [[ "$NOTICE" == *"hosting: headless"* ]] \
   && [[ "$NOTICE" == *"docs/operating/upgrading.md"* ]]; then
    pass "notice carries pull-before-restart ordering, verification verb, and the docs pointer"
else
    fail "notice missing ordering/verification/docs pointer: $NOTICE"
fi

if [[ "$NOTICE" == *"keeps working normally"* ]] \
   && [[ "$NOTICE" == *"once per watcher start"* ]] \
   && [[ "$NOTICE" == *"WATCHER_WINDOW='watcher'"* ]]; then
    pass "notice states normal operation continues, the once-per-start cadence, and the observed hosting value"
else
    fail "notice missing continue-normally/cadence/observed-value: $NOTICE"
fi

NOTICE_UNSET=$(_hosting_render_migration_notice "/r" "")
if [[ "$NOTICE_UNSET" == *"WATCHER_WINDOW='<unset>'"* ]]; then
    pass "unset WATCHER_WINDOW rendered as <unset> in the notice"
else
    fail "unset WATCHER_WINDOW not surfaced: $NOTICE_UNSET"
fi

# ---- 8-11: one-shot wiring in main.sh (structural) ------------------------

MAIN="$_script_dir/main.sh"

# The compute site must be the startup sweep (exactly one call of each
# helper in main.sh), keyed on the launcher's env contract.
n_detect=$(grep -c '_hosting_is_legacy ' "$MAIN" || true)
n_render=$(grep -c '_hosting_render_migration_notice ' "$MAIN" || true)
if [[ "$n_detect" == "1" && "$n_render" == "1" ]]; then
    pass "main.sh computes the notice at exactly one site (startup sweep) — once per lifecycle by construction"
else
    fail "expected exactly one detect+render site in main.sh (got detect=$n_detect render=$n_render)"
fi

# compose_report must own a dedicated section for it…
if grep -q -- '--- watcher hosting migration ---' "$MAIN"; then
    pass "compose_report renders the '--- watcher hosting migration ---' section"
else
    fail "section header missing from main.sh"
fi

# …the startup-sweep emit gate must include it (a legacy start with no
# other signal still emits)…
if grep -q -- '-n "$hosting_migration_now"' "$MAIN" \
   && grep -q 'compose_report "startup-sweep".*"\$hosting_migration_now"' "$MAIN"; then
    pass "startup-sweep gate + compose_report call carry the notice"
else
    fail "startup-sweep gate or compose call missing \$hosting_migration_now"
fi

# …and the steady-state compose_report call must NOT pass it (10th arg
# absent), so later cycles can never re-nag.
steady_call=$(grep -n 'compose_report "\$reason"' "$MAIN" | head -1)
if [[ -n "$steady_call" ]] && ! grep 'compose_report "\$reason"' "$MAIN" | grep -q 'hosting_migration'; then
    pass "steady-state compose_report call never carries the notice (no per-cycle nag)"
else
    fail "steady-state compose_report call unexpectedly references hosting_migration: $steady_call"
fi

# ---- summary --------------------------------------------------------------

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
