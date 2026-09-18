#!/usr/bin/env bash
# monitor/watcher/test-heartbeat-schema-agreement.sh
#
# EVERY HEARTBEAT FIELD THE CLASSIFIER READS IS ONE THE WRITER EMITS
# (your-org/nexus-code#1374). `pane-state.sh` read `monitor_handles` and
# `background_bash_count` from the heartbeat JSON for the whole life of the
# data, and nothing ever wrote them: the only production writer,
# `monitor/worker-heartbeat.sh`, emits ten keys and neither is among them
# (0 of 1,882 live heartbeats). A `max()` with a dead operand cannot fail,
# cannot log and cannot go red, so the exemption that keeps a busy worker
# from being retired silently rested on one regex while four documents
# asserted a defence in depth.
#
# A fixture that PLANTS a field cannot detect its absence in production —
# which is precisely how this persisted. This suite asks the SOURCE instead:
# the set of `.field` names `pane-state.sh` reads from a heartbeat file must
# be a subset of the set of keys `worker-heartbeat.sh` writes. The reader set
# is derived from the classifier's own `jq` calls against its heartbeat
# handle; the writer set from the writer's jq filter and its jq-less
# fallback. Both are extracted, never restated: a hand-copied list beside
# the code would be the dead-operand defect one level up.
#
# Population: monitor/pane-state.sh, monitor/worker-heartbeat.sh, and
# monitor/hooks/async-launch-detect.sh (which also writes rows into the
# heartbeat). A change to any of them can change the verdict.

set -u
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
# shellcheck source=_guard_population.sh
. "$_repo_root/monitor/_guard_population.sh"
gp_population() {
    printf '%s\n' monitor/pane-state.sh monitor/worker-heartbeat.sh monitor/hooks/async-launch-detect.sh
}
gp_handle "$@"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

READER="$_repo_root/monitor/pane-state.sh"
WRITER="$_repo_root/monitor/worker-heartbeat.sh"
HOOK="$_repo_root/monitor/hooks/async-launch-detect.sh"

# ---- the writer's key set --------------------------------------------------
# Keys of the jq filter object literal assembled in worker-heartbeat.sh, plus
# the `+ {key: …}` optional additions, plus the keys of the printf fallback.
writer_keys() {   # <writer-file>
    local f="$1"
    {
        # `jq_filter='{state: $state, …}'` block: every `name:` at line start
        # between the opening quote and the closing `}'`.
        awk '/jq_filter=.\{/{inb=1} inb{print} inb && /\}.$/{inb=0}' "$f" \
            | grep -oE '^[[:space:]]*(jq_filter=.\{)?[[:space:]]*[a-z_]+:' | grep -oE '[a-z_]+:' | tr -d ':'
        # `+ {key: $x}` additions
        grep -oE "\+ \{[a-z_]+:" "$f" | grep -oE '[a-z_]+' | grep -v '^$'
        # printf fallback: "key":
        grep -oE '"[a-z_]+":' "$f" | tr -d '":'
    } | sort -u
}
# The hook writes rows INTO the heartbeat: its top-level keys are also
# writer keys (it seeds a skeleton and rewrites external_waits).
hook_keys() {
    grep -oE '\{window: \$window, last_activity: \$now, external_waits: \[\], dismissed_waits: \[\]\}' "$1" \
        | grep -oE '[a-z_]+:' | tr -d ':' | sort -u
}
# ---- the reader's key set --------------------------------------------------
# Every `jq -r '.name …' "$hb_file"` / `"$hb"` in pane-state.sh, plus the
# external_waits filter which names its field in a multi-line jq program.
reader_keys() {   # <reader-file>
    local f="$1"
    {
        grep -oE "jq -r '\.[a-z_]+[^']*' \"\\\$(hb_file|hb)\"" "$f" | grep -oE "'\.[a-z_]+" | tr -d "'."
        grep -oE '\(\.external_waits \| type\)' "$f" | grep -oE 'external_waits'
    } | sort -u
}

echo "=== #1374: heartbeat fields read by pane-state.sh ⊆ fields written by worker-heartbeat.sh ==="
W=$(writer_keys "$WRITER"); H=$(hook_keys "$HOOK"); R=$(reader_keys "$READER")
ALLW=$(printf '%s\n%s\n' "$W" "$H" | grep -v '^$' | sort -u)
printf '  writer keys (%d): %s\n' "$(wc -l <<<"$ALLW")" "$(tr '\n' ' ' <<<"$ALLW")"
printf '  reader keys (%d): %s\n' "$(wc -l <<<"$R")" "$(tr '\n' ' ' <<<"$R")"
# POSITIVE CONTROLS on the extraction itself — an extractor that returns an
# empty set would make the subset assertion vacuously true.
if grep -qx 'last_activity' <<<"$ALLW" && grep -qx 'external_waits' <<<"$ALLW" && (( $(wc -l <<<"$ALLW") >= 8 )); then
    ok "writer extraction sees the known keys (last_activity, external_waits; >=8 total)"
else
    bad "writer extraction is broken: [$(tr '\n' ' ' <<<"$ALLW")]"
fi
if grep -qx 'last_activity' <<<"$R" && grep -qx 'scheduled_wakeup_at' <<<"$R" && (( $(wc -l <<<"$R") >= 4 )); then
    ok "reader extraction sees the known reads (last_activity, scheduled_wakeup_at; >=4 total)"
else
    bad "reader extraction is broken: [$(tr '\n' ' ' <<<"$R")]"
fi
orphans=$(comm -23 <(printf '%s\n' "$R") <(printf '%s\n' "$ALLW"))
if [[ -z "$orphans" ]]; then
    ok "every field pane-state.sh reads from the heartbeat is one the writer emits"
else
    bad "pane-state.sh reads heartbeat field(s) NOTHING writes: $(tr '\n' ' ' <<<"$orphans") — a dead arm (#1374)"
fi
# The two fields #1374 was about must be gone from the reader entirely — a
# reader of a never-written field is the defect, whatever it does with it.
for dead in monitor_handles background_bash_count; do
    if grep -qx "$dead" <<<"$R"; then bad "pane-state.sh still reads .$dead from the heartbeat"; else ok "pane-state.sh no longer reads .$dead"; fi
done

# ---- POTENCY: a planted reader of a phantom field goes RED -----------------
echo "=== potency: a planted read of a never-written field is caught ==="
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$READER" "$T/pane-state.sh"
printf '\nphantom=$(jq -r %s.phantom_field // 0%s "$hb_file" 2>/dev/null)\n' "'" "'" >> "$T/pane-state.sh"
R2=$(reader_keys "$T/pane-state.sh")
orphans2=$(comm -23 <(printf '%s\n' "$R2") <(printf '%s\n' "$ALLW"))
if [[ "$orphans2" == "phantom_field" ]]; then
    ok "POTENCY: the planted .phantom_field read is reported as unwritten"
else
    bad "POTENCY: planted phantom read NOT caught (orphans=[$orphans2])"
fi
# …and the pre-#1374 shape, reconstructed, is caught the same way.
printf '\nmon=$(jq -r %s.monitor_handles // 0%s "$hb_file" 2>/dev/null)\n' "'" "'" >> "$T/pane-state.sh"
R3=$(reader_keys "$T/pane-state.sh")
if grep -qx monitor_handles <<<"$(comm -23 <(printf '%s\n' "$R3") <(printf '%s\n' "$ALLW"))"; then
    ok "POTENCY: the original dead read (.monitor_handles) is reported as unwritten"
else
    bad "POTENCY: the original dead read would NOT be caught"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
