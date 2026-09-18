#!/usr/bin/env bash
# Tests for monitor/slow-band-drift.sh and monitor/slow-band-known-red.tsv —
# the enumerated tolerated-red set that lets the SLOW band be a blocking gate
# while a known red is outstanding (your-org/nexus-code#737).
#
# Run: bash monitor/test-slow-band-drift.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# The checker carries its own --selftest over planted deviations; this file runs
# that, then does the part a selftest structurally cannot: assert things about
# the REAL tolerance file that ships, and MUTATE the checker to prove the
# selftest is load-bearing rather than decorative.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIFT="$HERE/slow-band-drift.sh"
KNOWN="$HERE/slow-band-known-red.tsv"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

for f in "$DRIFT" "$KNOWN"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done
ok "preconditions: checker and tolerance file present"

echo "-- the checker's own negative control --"
if bash "$DRIFT" --selftest > "$TMP/self.out" 2>&1; then
  ok "--selftest exits 0"
else
  bad "--selftest exits $?"; sed 's/^/       /' "$TMP/self.out"
fi
for state in NEW-RED STALE-TOLERATION UNACCOUNTED; do
  if grep -q "$state" "$TMP/self.out"; then
    ok "--selftest exercises $state"
  else
    bad "--selftest never exercises $state — a state with no negative control"
  fi
done

echo "-- the REAL tolerance file --"
# It must PARSE. A tolerance file that only the CI job ever parses is one that
# breaks in CI rather than here.
printf 'monitor/watcher/test-nonexistent-xyz.sh\tFAIL\t1\t0\t0\n' > "$TMP/dummy"
bash "$DRIFT" "$TMP/dummy" "$KNOWN" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then
  ok "the shipped tolerance file parses (rc=1 = findings, not rc=2 = refusal)"
else
  bad "the shipped tolerance file gave rc=$rc; 2 means it does not parse"
fi

# Every tolerated entry must name a test that EXISTS. An entry pointing at a
# renamed or deleted file is permanently UNACCOUNTED, which turns the gate into
# a nuisance and gets the whole mechanism switched off.
missing=0
while IFS=$'\t' read -r p _issue _reason; do
  case "$p" in ''|'#'*) continue ;; esac
  [ -f "$HERE/../$p" ] || { bad "tolerated entry names a file that does not exist: $p"; missing=1; }
done < "$KNOWN"
[ "$missing" -eq 0 ] && ok "every tolerated entry names a test file that exists"

# Every tolerated entry must be a test the band would actually SELECT, or the
# toleration silently covers nothing.
selectable=0; unselectable=0
while IFS=$'\t' read -r p _issue _reason; do
  case "$p" in ''|'#'*) continue ;; esac
  if grep -q 'SLOW_TESTS\|RUN_INTEGRATION' "$HERE/../$p" 2>/dev/null; then
    selectable=$((selectable + 1))
  else
    bad "tolerated entry is not a SLOW/integration-gated test: $p"; unselectable=1
  fi
done < "$KNOWN"
[ "$unselectable" -eq 0 ] && ok "every tolerated entry ($selectable) is a gated band test"

echo "-- mutants of the CHECKER (the selftest must be load-bearing) --"
mutate() {  # mutate <label> <sed-expr>
  local label="$1" expr="$2"
  cp "$DRIFT" "$TMP/mut.sh"
  sed -i "$expr" "$TMP/mut.sh"
  if cmp -s "$DRIFT" "$TMP/mut.sh"; then
    bad "$label: mutation changed nothing — a no-op mutant proves nothing"; return
  fi
  if bash "$TMP/mut.sh" --selftest >/dev/null 2>&1; then
    bad "$label: MUTANT SURVIVED its own selftest"
  else
    ok "$label -> selftest goes red"
  fi
}

# M1 — treat every status as green. NEW-RED can never fire.
# The predicate the checker dispatches on is _status_class's terminal arm, not
# _is_green: #1283 made check() read `klass=$(_status_class …)` directly, which
# left _is_green DEAD — and a mutant of dead code SURVIVES (measured: the old
# anchor was a no-op, the re-anchored one survived). Turn the fail-closed `*)`
# arm green: every non-PASS status then reads as a pass, and the selftest's
# NEW-RED, SKIP-is-red and unknown-token cases must all catch it.
mutate "everything-is-green" "s|^        \*)       printf 'red' ;;|        *)       printf 'green' ;;|"
# M2 — drop the STALE-TOLERATION direction. The list becomes append-only, which
#      is the failure mode #737 names: a tolerance that only ever grows.
mutate "no-stale-toleration" 's|stale+=|_discarded+=|'
# M3 — stop collecting UNACCOUNTED. A toleration for a test nobody runs any more
#      reads exactly like one that is working.
mutate "no-unaccounted" 's|unaccounted+=|_discarded2+=|'

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || { echo "TESTS FAILED"; exit 1; }
echo "ALL TESTS PASSED"
