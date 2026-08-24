#!/usr/bin/env bash
# Unit tests for the operator-local settings overlay
# (`monitor/resolve-settings.sh`, your-org/nexus-code#614 second defect).
#
# Run: bash monitor/watcher/test-settings-overlay.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE PROPERTY UNDER TEST is not "does the merge work" — it is
# **an operator's local keys are never silently dropped**. The bug this
# closes downgraded every worker off the operator's chosen model with no
# error, because the model pin lived in a tracked file and the obvious
# pull-conflict resolution discarded it. So the failure-path cases below
# all assert the same thing from different angles: when the overlay
# cannot be applied, the resolver must FAIL, not quietly emit the
# tracked defaults. A resolver that fell back would pass a naive
# "returns a usable settings path" test while reproducing the defect
# exactly.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

RESOLVER="$_test_dir/../resolve-settings.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/monitor"
BASE="$WORK/monitor/worker-settings.json"
LOCAL="$WORK/monitor/worker-settings.local.json"

write_base() {
    cat > "$BASE" <<'JSON'
{
  "skipDangerousModePermissionPrompt": true,
  "env": { "DISABLE_AUTOUPDATER": "1" },
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "heartbeat.sh" } ] } ],
    "Notification": [ { "hooks": [ { "type": "command", "command": "notify.sh" } ] } ]
  }
}
JSON
}

echo "== pass-through when no overlay exists =="

write_base
rm -f "$LOCAL"
got=$("$RESOLVER" "$BASE"); rc=$?
assert_rc "resolves cleanly" "$rc" "0"
assert_eq "echoes the tracked path unchanged" "$got" "$BASE"
assert_no_file "no generated file is created" "$WORK/monitor/.state/settings/worker-settings.effective.json"

echo "== overlay merges, local wins, tracked structure survives =="

write_base
cat > "$LOCAL" <<'JSON'
{ "model": "claude-opus-5", "tui": "fullscreen" }
JSON
got=$("$RESOLVER" "$BASE"); rc=$?
assert_rc "resolves cleanly" "$rc" "0"
assert_eq "emits the generated effective path" "$got" \
    "$WORK/monitor/.state/settings/worker-settings.effective.json"
assert_eq "operator model pin present" "$(jq -r '.model' "$got")" "claude-opus-5"
assert_eq "operator tui pin present"   "$(jq -r '.tui' "$got")" "fullscreen"
# THE regression guard: a local file that mentions only `model` must not
# cost the worker its hooks. A shallow (non-recursive) merge would drop
# the whole hooks tree and every heartbeat with it.
assert_eq "tracked hooks survive a partial overlay" \
    "$(jq -r '.hooks.Stop[0].hooks[0].command' "$got")" "heartbeat.sh"
assert_eq "tracked env survives" "$(jq -r '.env.DISABLE_AUTOUPDATER' "$got")" "1"
assert_eq "unrelated tracked keys survive" \
    "$(jq -r '.skipDangerousModePermissionPrompt' "$got")" "true"

echo "== local overrides a key the tracked file also sets =="

write_base
cat > "$LOCAL" <<'JSON'
{ "skipDangerousModePermissionPrompt": false, "env": { "EXTRA": "yes" } }
JSON
got=$("$RESOLVER" "$BASE")
assert_eq "scalar overridden by local" "$(jq -r '.skipDangerousModePermissionPrompt' "$got")" "false"
assert_eq "nested object MERGES rather than replacing" \
    "$(jq -r '.env.DISABLE_AUTOUPDATER' "$got")" "1"
assert_eq "  and gains the local key" "$(jq -r '.env.EXTRA' "$got")" "yes"

echo "== arrays replace wholesale (documented hook semantics) =="

write_base
cat > "$LOCAL" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "mine.sh" } ] } ] } }
JSON
got=$("$RESOLVER" "$BASE")
assert_eq "overridden event uses the local array" \
    "$(jq -r '.hooks.Stop[0].hooks[0].command' "$got")" "mine.sh"
assert_eq "  exactly one entry (replaced, not appended)" \
    "$(jq -r '.hooks.Stop[0].hooks | length' "$got")" "1"
assert_eq "untouched event keeps the tracked hooks" \
    "$(jq -r '.hooks.Notification[0].hooks[0].command' "$got")" "notify.sh"

echo "== FAIL LOUD: never silently fall back to the tracked defaults =="

# Each case drives a distinct failure and asserts BOTH that the resolver
# refuses AND that it did not emit the tracked path — emitting it is
# precisely the silent downgrade.
write_base
printf '{ "model": "claude-opus-5",\n' > "$LOCAL"   # truncated / invalid JSON
out=$("$RESOLVER" "$BASE" 2>"$WORK/err"); rc=$?
assert_rc "malformed overlay -> non-zero" "$rc" "5"
assert_empty "  emits NO path (a path would be consumed as settings)" "$out"
assert_contains "  and says why, naming the file" "$(cat "$WORK/err")" "worker-settings.local.json"
assert_contains "  and states the refusal" "$(cat "$WORK/err")" "refusing to spawn"

write_base
printf '[1,2,3]\n' > "$LOCAL"
out=$("$RESOLVER" "$BASE" 2>"$WORK/err"); rc=$?
assert_eq "overlay that is not an object -> refused" "$([[ $rc -ne 0 ]] && echo refused)" "refused"
assert_empty "  emits no path" "$out"

write_base
printf 'not json at all' > "$BASE"
printf '{"model":"x"}' > "$LOCAL"
out=$("$RESOLVER" "$BASE" 2>"$WORK/err"); rc=$?
assert_rc "malformed BASE -> non-zero" "$rc" "6"
assert_empty "  emits no path" "$out"

# Missing base is a distinct, earlier failure.
out=$("$RESOLVER" "$WORK/monitor/does-not-exist.json" 2>"$WORK/err"); rc=$?
assert_rc "absent base -> non-zero" "$rc" "3"
assert_contains "  names the missing file" "$(cat "$WORK/err")" "does-not-exist.json"

# Unwritable state dir. Skipped for root, which can write anywhere.
write_base
printf '{"model":"claude-opus-5"}' > "$LOCAL"
if [[ "$(id -u)" != "0" ]]; then
    # Remove the settings dir a previous case created — `mkdir -p` on an
    # already-existing directory succeeds even under a read-only parent,
    # so leaving it in place tests nothing.
    rm -rf "$WORK/monitor/.state/settings"
    mkdir -p "$WORK/monitor/.state"
    chmod 500 "$WORK/monitor/.state"
    out=$("$RESOLVER" "$BASE" 2>"$WORK/err"); rc=$?
    chmod 700 "$WORK/monitor/.state"
    assert_eq "unwritable state dir -> refused" "$([[ $rc -ne 0 ]] && echo refused)" "refused"
    assert_empty "  emits no path" "$out"
    assert_contains "  and explains" "$(cat "$WORK/err")" "refusing to spawn"
else
    printf '  SKIP: unwritable-state-dir case (running as root)\n'
fi

echo "== NEGATIVE CONTROL: the fallback bug would be caught =="

# Prove the failure assertions above are not vacuous by demonstrating
# what a fallback resolver looks like — it returns 0 and emits the
# tracked path, which is exactly what the assertions reject. If the real
# resolver ever regressed to this shape, the cases above would fail.
fallback_resolver() { printf '%s' "$2"; return 0; }
write_base
printf '{ "model": broken\n' > "$LOCAL"
fb_out=$(fallback_resolver x "$BASE"); fb_rc=$?
assert_rc "a fallback resolver returns 0 on malformed overlay" "$fb_rc" "0"
assert_eq "  and hands back the tracked path (the silent downgrade)" "$fb_out" "$BASE"
real_out=$("$RESOLVER" "$BASE" 2>/dev/null); real_rc=$?
assert_eq "the REAL resolver behaves differently on that same input" \
    "$([[ "$real_rc" -ne "$fb_rc" || "$real_out" != "$fb_out" ]] && echo differs)" "differs"

echo "== generated file is not world-readable =="

write_base
printf '{"model":"claude-opus-5"}' > "$LOCAL"
got=$("$RESOLVER" "$BASE")
assert_eq "effective settings are 0600" "$(stat -c %a "$got" 2>/dev/null)" "600"

echo "== idempotent: repeated resolution is stable =="

a=$("$RESOLVER" "$BASE"); sum_a=$(md5sum < "$a")
b=$("$RESOLVER" "$BASE"); sum_b=$(md5sum < "$b")
assert_eq "same path both times" "$a" "$b"
assert_eq "same content both times" "$sum_a" "$sum_b"

th_summary_and_exit
