#!/usr/bin/env bash
# Unit tests for `ng log-action` (cmd_log_action in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-log-action.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: log-action writes one JSON line per call to
# $STATE_DIR/action-log.jsonl. No network, no `gh`. Build a minimal
# fake-nexus tree, drive `ng log-action` with various flag shapes,
# and assert the JSON's shape via `jq`.
#
# Coverage map (from the audit's gap list, your-org/nexus-code#39):
#   - Required-arg validation (missing agent, missing --event).
#   - Base JSON shape: ts, agent, event keys.
#   - Optional --note: present iff non-empty.
#   - Repeatable --extra k=v: each k/v gets folded as a string field.
#   - State-dir resolution: NEXUS_STATE_DIR override honored.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

WORK=$(mktemp -d -t nexus-ng-log-action-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Minimal fake nexus. ng resolves config/load.sh + mint-token.sh by
# script-relative path; cmd_log_action doesn't call `gh`, so the
# mint-token stub is defensive only.
FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
NG="$FAKE_NEXUS/monitor/ng"

cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'default-org/default-repo' ;;
    github.user_login)  printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
echo "mint-token must not be called by log-action" >&2
exit 99
STUB
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

# Run ng with hermetic env. NEXUS_STATE_DIR pinned to a fresh dir per
# call so each test owns its own action-log.jsonl.
run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3" _state_dir="$4"; shift 4
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
        NEXUS_STATE_DIR="$_state_dir" \
        "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# ---- Test 1: required-arg validation ------------------------------------

echo '=== required-arg validation ==='
STATE1="$WORK/state-1"; mkdir -p "$STATE1"

run_ng out err rc "$STATE1" log-action
assert_eq        "no agent → exit non-zero"          "$rc" "1"
assert_contains  "stderr mentions usage"             "$err" "usage: ng log-action"
assert_no_file   "no log file written"                "$STATE1/action-log.jsonl"

run_ng out err rc "$STATE1" log-action my-agent
assert_eq        "no --event → exit non-zero"        "$rc" "1"
assert_contains  "stderr names --event"              "$err" "--event is required"
assert_no_file   "no log file on missing --event"     "$STATE1/action-log.jsonl"

run_ng out err rc "$STATE1" log-action my-agent --event smoke --bogus thing
assert_eq        "unknown flag → exit non-zero"      "$rc" "1"
assert_contains  "stderr names unknown flag"         "$err" "unknown flag: --bogus"

# ---- Test 2: base JSON shape (ts/agent/event) ---------------------------

echo '=== base JSON shape ==='
STATE2="$WORK/state-2"; mkdir -p "$STATE2"
run_ng out err rc "$STATE2" log-action validator --event smoke-test
assert_eq          "exit 0"                            "$rc" "0"
assert_file_exists "log file created"                  "$STATE2/action-log.jsonl"

# One line, valid JSON, fields populated.
line=$(<"$STATE2/action-log.jsonl")
assert_eq        "agent field"                       \
                 "$(jq -r '.agent' <<<"$line")"      "validator"
assert_eq        "event field"                       \
                 "$(jq -r '.event' <<<"$line")"      "smoke-test"
# ts must parse as an ISO-8601 timestamp.
ts=$(jq -r '.ts' <<<"$line")
assert_contains  "ts present"                        "$ts" "T"
# No note key (since no --note passed).
note_key=$(jq -r 'has("note")' <<<"$line")
assert_eq        "no note key when --note omitted"   "$note_key" "false"

# ---- Test 3: --note included when non-empty -----------------------------

echo '=== --note inclusion ==='
STATE3="$WORK/state-3"; mkdir -p "$STATE3"
run_ng out err rc "$STATE3" log-action validator --event smoke --note "everything looks ok"
assert_eq        "exit 0"                            "$rc" "0"
line=$(<"$STATE3/action-log.jsonl")
assert_eq        "note included"                     \
                 "$(jq -r '.note' <<<"$line")"       "everything looks ok"

# Empty --note must be excluded (the `if $note != ""` branch).
STATE3b="$WORK/state-3b"; mkdir -p "$STATE3b"
run_ng out err rc "$STATE3b" log-action validator --event smoke --note ""
assert_eq        "exit 0"                            "$rc" "0"
line=$(<"$STATE3b/action-log.jsonl")
note_key=$(jq -r 'has("note")' <<<"$line")
assert_eq        "empty --note dropped"              "$note_key" "false"

# ---- Test 4: --extra k=v folding ---------------------------------------

echo '=== --extra k=v folding (repeatable) ==='
STATE4="$WORK/state-4"; mkdir -p "$STATE4"
run_ng out err rc "$STATE4" log-action validator --event wrap-up \
    --extra "upload=ok" --extra "rocket=skipped" --extra "issue=42"
assert_eq        "exit 0"                            "$rc" "0"
line=$(<"$STATE4/action-log.jsonl")
assert_eq        "upload extra"                      \
                 "$(jq -r '.upload' <<<"$line")"     "ok"
assert_eq        "rocket extra"                      \
                 "$(jq -r '.rocket' <<<"$line")"     "skipped"
assert_eq        "issue extra (stays string)"        \
                 "$(jq -r '.issue' <<<"$line")"      "42"

# Value containing `=` survives the `${kv#*=}` split (only the first
# `=` splits key from value).
STATE4b="$WORK/state-4b"; mkdir -p "$STATE4b"
run_ng out err rc "$STATE4b" log-action validator --event q \
    --extra "url=https://x.example/a=b&c=d"
assert_eq        "exit 0"                            "$rc" "0"
line=$(<"$STATE4b/action-log.jsonl")
assert_eq        "value with embedded ="             \
                 "$(jq -r '.url' <<<"$line")"        "https://x.example/a=b&c=d"

# Empty key (just `=v`) is silently skipped.
STATE4c="$WORK/state-4c"; mkdir -p "$STATE4c"
run_ng out err rc "$STATE4c" log-action validator --event q --extra "=orphan"
assert_eq        "exit 0"                            "$rc" "0"
line=$(<"$STATE4c/action-log.jsonl")
# Object has the three standard keys + nothing extra.
keys=$(jq -r 'keys | sort | join(",")' <<<"$line")
assert_eq        "empty-key extra skipped"           "$keys" "agent,event,ts"

# ---- Test 5: append semantics (multiple calls) --------------------------

echo '=== append semantics ==='
STATE5="$WORK/state-5"; mkdir -p "$STATE5"
run_ng out err rc "$STATE5" log-action a1 --event one
run_ng out err rc "$STATE5" log-action a2 --event two
run_ng out err rc "$STATE5" log-action a3 --event three
line_count=$(wc -l < "$STATE5/action-log.jsonl")
assert_eq        "three calls → three lines"         "$line_count" "3"

# Each line valid JSON, agent matches call order.
agents=$(jq -r '.agent' "$STATE5/action-log.jsonl" | paste -sd,)
assert_eq        "append order preserved"            "$agents" "a1,a2,a3"

# ---- summary ------------------------------------------------------------

th_summary_and_exit
