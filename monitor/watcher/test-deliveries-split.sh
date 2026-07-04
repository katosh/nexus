#!/usr/bin/env bash
# Tests for the deliveries flag SPLIT (your-org/nexus-code, the #244
# follow-up). `snapshot_deliveries` serves two independent concerns:
#
#   - in-$REPO (asset-nexus) comment surfacing  — no @bot-mention needed,
#     emitted as `issue=`/`pr=`/`pr_review=`/`issue_new=` shapes, AND
#   - cross-repo @bot-mention surfacing         — emitted as the
#     `mention=<owner>/<repo>` shape.
#
# Each concern has its own independent flag that gates its emit path:
#   monitor.deliveries.asset_enabled        gates the in-$REPO emit
#   monitor.deliveries.bot_mention_enabled  gates the cross-repo `mention=` emit
# Both resolve directly from their own key with a plain default of `true`;
# there is NO umbrella. The former `deliveries_enabled` umbrella was removed
# (operator directive on #344) — a stale `deliveries_enabled` in a user's
# config is simply ignored. The cursor advances regardless of the gate — a
# gated-off delivery is CONSUMED (not re-walked), just not surfaced.
#
# Two layers under test:
#   A. Gate layer (`_deliveries.sh`): in-$REPO surfaces iff asset-enabled;
#      cross-repo `mention=` surfaces iff bot-mention-enabled; cursor still
#      advances when gated off.
#   B. Config layer (`_config.sh`): each flag resolves from its own key,
#      defaults true, env overrides are independent, and a stale
#      `deliveries_enabled` value is genuinely ignored.
set -uo pipefail

_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — %q not found in:\n%s\n' "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — %q UNEXPECTEDLY present in:\n%s\n' "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---------------------------------------------------------------------------
# Harness — mirrors test-snapshot-deliveries.sh: a curl mock that branches on
# the URL and serves canned listing + per-delivery payloads.
# ---------------------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"
MINT_JWT_BIN="$WORK/mint-jwt-stub.sh"
cat > "$MINT_JWT_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'fake.jwt.value'
STUB
chmod +x "$MINT_JWT_BIN"

export STATE_DIR REPO USER_LOGIN MINT_JWT_BIN

. "$_test_dir/_github.sh"
. "$_test_dir/_deliveries.sh"

mkdir -p "$WORK/fixtures"
LIST_BODY="$WORK/fixtures/list.json"
LIST_HDR="$WORK/fixtures/list.hdr"
# One in-$REPO event (1001) + one cross-repo event (1004). Both authored by
# the operator (operator) so the universal user-author chokepoint keeps both;
# the only thing that decides surfacing is the split gate.
cat > "$LIST_BODY" <<'JSON'
[
  {"id": 1004, "guid": "guid-1004", "event": "issue_comment", "action": "created"},
  {"id": 1001, "guid": "guid-1001", "event": "issue_comment", "action": "created"}
]
JSON
printf 'HTTP/2 200 \n\n' > "$LIST_HDR"

mk_detail() {
    local id="$1" event="$2" action="$3" payload="$4"
    cat > "$WORK/fixtures/${id}.json" <<JSON
{
  "id": ${id},
  "event": "${event}",
  "action": "${action}",
  "request": {
    "headers": {"X-GitHub-Event": "${event}"},
    "payload": ${payload}
  }
}
JSON
}

# 1001: in-$REPO issue comment -> `issue=` shape (the asset-surfacing concern).
mk_detail 1001 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/your-nexus"},
  "issue": {"number": 11, "pull_request": null},
  "comment": {"id": 91001, "user": {"login": "operator"}, "body": "in-repo asset comment"}
}'

# 1004: cross-repo issue comment -> `mention=` shape (the bot-mention concern).
mk_detail 1004 issue_comment created '{
  "action": "created",
  "repository": {"full_name": "your-org/some-other-repo"},
  "issue": {"number": 88, "pull_request": null},
  "comment": {"id": 94004, "user": {"login": "operator"}, "body": "Hey @your-org-bot, look at this?"}
}'

curl() {
    local hdr_target="" body_target="" url="" status_w=0 prev=""
    for arg in "$@"; do
        case "$prev" in
            -D) hdr_target="$arg"; prev=""; continue ;;
            -o) body_target="$arg"; prev=""; continue ;;
            -w) status_w=1; prev=""; continue ;;
            -H) prev=""; continue ;;
        esac
        case "$arg" in
            -D|-o|-H|-w) prev="$arg" ;;
            -sS) ;;
            -*)  ;;
            http*) url="$arg" ;;
        esac
    done
    local code=200 src_hdr="" src_body=""
    case "$url" in
        *'/app/hook/deliveries?per_page='*)
            src_hdr="$LIST_HDR"; src_body="$LIST_BODY" ;;
        *'/app/hook/deliveries/'*)
            local id="${url##*/}"; id="${id%%\?*}"
            src_body="$WORK/fixtures/${id}.json"
            if [[ ! -f "$src_body" ]]; then
                code=404; src_body="$WORK/fixtures/.empty"
                printf '{"message":"Not Found"}' > "$src_body"
            fi
            src_hdr="$WORK/fixtures/.detail-hdr"
            printf 'HTTP/2 %s \n\n' "$code" > "$src_hdr" ;;
        *)
            code=404; src_body="$WORK/fixtures/.empty"; : > "$src_body"
            src_hdr="$WORK/fixtures/.detail-hdr"
            printf 'HTTP/2 %s \n\n' "$code" > "$src_hdr" ;;
    esac
    [[ -n "$hdr_target" ]] && cp "$src_hdr"  "$hdr_target"
    [[ -n "$body_target" ]] && cp "$src_body" "$body_target"
    (( status_w == 1 )) && printf '%s' "$code"
    return 0
}
export -f curl

# Reset cursor + processed-comments before each scenario so every run walks
# the same two deliveries fresh.
reset_state() {
    rm -f "$STATE_DIR/last-delivery-cursor.txt" \
          "$STATE_DIR/processed-comments.txt" \
          "$STATE_DIR/deliveries-queue.lines"
}

run_split() {
    # $1=asset $2=bot_mention -> stdout of the surfacing pipeline.
    reset_state
    DELIVERIES_ASSET_ENABLED="$1" DELIVERIES_BOT_MENTION_ENABLED="$2" \
        snapshot_deliveries 2>/dev/null | _filter_to_user_author
}

IN_REPO_LINE="issue=11 id=91001 author=operator"
CROSS_REPO_LINE="mention=your-org/some-other-repo"

echo '=== A. gate layer: both flags ON -> both concerns surface ==='
out=$(run_split true true)
assert_contains "asset+botmention ON: in-\$REPO issue= surfaces"  "$out" "$IN_REPO_LINE"
assert_contains "asset+botmention ON: cross-repo mention= surfaces" "$out" "$CROSS_REPO_LINE"

echo '=== A. asset OFF, bot_mention ON -> only cross-repo surfaces ==='
out=$(run_split false true)
assert_not_contains "asset OFF: in-\$REPO issue= suppressed"      "$out" "$IN_REPO_LINE"
assert_contains     "bot_mention ON: cross-repo mention= surfaces" "$out" "$CROSS_REPO_LINE"

echo '=== A. asset ON, bot_mention OFF -> only in-$REPO surfaces ==='
out=$(run_split true false)
assert_contains     "asset ON: in-\$REPO issue= surfaces"          "$out" "$IN_REPO_LINE"
assert_not_contains "bot_mention OFF: cross-repo mention= suppressed" "$out" "$CROSS_REPO_LINE"

echo '=== A. both OFF -> neither surfaces, but cursor still advances ==='
out=$(run_split false false)
assert_not_contains "both OFF: in-\$REPO suppressed"   "$out" "$IN_REPO_LINE"
assert_not_contains "both OFF: cross-repo suppressed"  "$out" "$CROSS_REPO_LINE"
assert_eq "both OFF: cursor still advanced (delivery consumed, not re-walked)" \
    "$(cat "$STATE_DIR/last-delivery-cursor.txt" 2>/dev/null)" "guid-1004"

echo '=== A. unset both (legacy direct-call) -> both surface (pre-split behaviour) ==='
# Both gates default to "emit" when the vars are unset, so a pre-split caller
# (or a test that never sets them) keeps the old surface-everything behaviour.
unset DELIVERIES_ASSET_ENABLED DELIVERIES_BOT_MENTION_ENABLED
reset_state
out=$(snapshot_deliveries 2>/dev/null | _filter_to_user_author)
assert_contains "unset: in-\$REPO issue= surfaces (default emit)"   "$out" "$IN_REPO_LINE"
assert_contains "unset: cross-repo mention= surfaces (default emit)" "$out" "$CROSS_REPO_LINE"

# ---------------------------------------------------------------------------
# B. Config layer — `_config.sh` resolution. Each flag resolves directly from
# its own key with a plain default of `true`, plus its scoped env override.
# No umbrella. The `_cfg` stub mimics an absent key by echoing the
# caller-supplied default ($2), exactly as `config/load.sh` does on a miss.
# Sourced in a clean bash so `_config.sh`'s ~50 globals can't clobber this
# harness.
# ---------------------------------------------------------------------------

CFG_STUB="$WORK/cfg-default-stub.sh"
cat > "$CFG_STUB" <<'STUB'
#!/usr/bin/env bash
# $1 = config key, $2 = default. Absent-key behaviour: echo the default.
printf '%s' "${2:-}"
STUB
chmod +x "$CFG_STUB"

resolve() {
    # $1 = var name to print; remaining args = env assignments.
    local var="$1"; shift
    env "$@" _cfg="$CFG_STUB" NEXUS_ROOT="$WORK" \
        bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${'"$var"':-}"' \
        _ "$_test_dir/_config.sh"
}

echo '=== B. defaults: no keys set -> both flags default true ==='
assert_eq "asset_enabled defaults true" \
    "$(resolve DELIVERIES_ASSET_ENABLED \
        -u MONITOR_DELIVERIES_ASSET_ENABLED -u MONITOR_DELIVERIES_BOT_MENTION_ENABLED)" "true"
assert_eq "bot_mention_enabled defaults true" \
    "$(resolve DELIVERIES_BOT_MENTION_ENABLED \
        -u MONITOR_DELIVERIES_ASSET_ENABLED -u MONITOR_DELIVERIES_BOT_MENTION_ENABLED)" "true"

echo '=== B. independence: each flag resolves from its OWN key (default true) ==='
# NB: `env` requires every `-u VAR` BEFORE any `VAR=value` assignment.
assert_eq "asset env=false overrides default-true" \
    "$(resolve DELIVERIES_ASSET_ENABLED \
        -u MONITOR_DELIVERIES_BOT_MENTION_ENABLED \
        MONITOR_DELIVERIES_ASSET_ENABLED=false)" "false"
assert_eq "bot_mention unaffected when only asset is forced off" \
    "$(resolve DELIVERIES_BOT_MENTION_ENABLED \
        -u MONITOR_DELIVERIES_BOT_MENTION_ENABLED \
        MONITOR_DELIVERIES_ASSET_ENABLED=false)" "true"
assert_eq "bot_mention env=false overrides default-true" \
    "$(resolve DELIVERIES_BOT_MENTION_ENABLED \
        -u MONITOR_DELIVERIES_ASSET_ENABLED \
        MONITOR_DELIVERIES_BOT_MENTION_ENABLED=false)" "false"
assert_eq "asset unaffected when only bot_mention is forced off" \
    "$(resolve DELIVERIES_ASSET_ENABLED \
        -u MONITOR_DELIVERIES_ASSET_ENABLED \
        MONITOR_DELIVERIES_BOT_MENTION_ENABLED=false)" "true"

echo '=== B. deprecated umbrella REMOVED: a stale deliveries_enabled is ignored ==='
# The operator directive (#344): a stale `deliveries_enabled` setting must be
# silently ignored — no fallback, no propagation. Prove it two ways.
#
# (1) Stale ENV: MONITOR_DELIVERIES_ENABLED=false must NOT leak into either
#     flag — both stay at their own default (true).
assert_eq "stale env MONITOR_DELIVERIES_ENABLED=false ignored — asset stays default true" \
    "$(resolve DELIVERIES_ASSET_ENABLED \
        -u MONITOR_DELIVERIES_ASSET_ENABLED -u MONITOR_DELIVERIES_BOT_MENTION_ENABLED \
        MONITOR_DELIVERIES_ENABLED=false)" "true"
assert_eq "stale env MONITOR_DELIVERIES_ENABLED=false ignored — bot_mention stays default true" \
    "$(resolve DELIVERIES_BOT_MENTION_ENABLED \
        -u MONITOR_DELIVERIES_ASSET_ENABLED -u MONITOR_DELIVERIES_BOT_MENTION_ENABLED \
        MONITOR_DELIVERIES_ENABLED=false)" "true"
#
# (2) Stale CONFIG KEY: a user's nexus.yml still carrying
#     `monitor.deliveries_enabled: false` must be ignored — `_config.sh` never
#     queries that key, so the new flags stay at their own default (true). A
#     dedicated stub returns false for the umbrella key and the default for
#     everything else; if any fallback survived, the flags would read false.
STALE_STUB="$WORK/cfg-stale-umbrella-stub.sh"
cat > "$STALE_STUB" <<'STUB'
#!/usr/bin/env bash
# $1 = config key, $2 = default. Simulate a nexus.yml that still carries the
# deprecated monitor.deliveries_enabled: false; every other key is absent.
case "$1" in
    monitor.deliveries_enabled) printf '%s' false ;;
    *) printf '%s' "${2:-}" ;;
esac
STUB
chmod +x "$STALE_STUB"
stale_asset=$(env -u MONITOR_DELIVERIES_ASSET_ENABLED -u MONITOR_DELIVERIES_BOT_MENTION_ENABLED \
    -u MONITOR_DELIVERIES_ENABLED _cfg="$STALE_STUB" NEXUS_ROOT="$WORK" \
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${DELIVERIES_ASSET_ENABLED:-}"' \
    _ "$_test_dir/_config.sh")
assert_eq "stale config deliveries_enabled:false ignored — asset stays true" "$stale_asset" "true"
stale_bot=$(env -u MONITOR_DELIVERIES_ASSET_ENABLED -u MONITOR_DELIVERIES_BOT_MENTION_ENABLED \
    -u MONITOR_DELIVERIES_ENABLED _cfg="$STALE_STUB" NEXUS_ROOT="$WORK" \
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${DELIVERIES_BOT_MENTION_ENABLED:-}"' \
    _ "$_test_dir/_config.sh")
assert_eq "stale config deliveries_enabled:false ignored — bot_mention stays true" "$stale_bot" "true"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
