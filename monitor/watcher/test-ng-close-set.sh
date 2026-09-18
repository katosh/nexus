#!/usr/bin/env bash
# monitor/watcher/test-ng-close-set.sh — `ng close-set` (your-org/nexus-code#1444):
# a bulk close with PER-ISSUE verification. Driven against a STATEFUL gh stub
# (a PATCH flips a per-issue state file; a GET reads it) so "the close was
# silently skipped" is a state the stub can exhibit and the verb must catch.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"
WORK=$(mktemp -d -t nexus-ng-closeset-XXXXXX); trap 'rm -rf "$WORK"' EXIT
FAKE="$WORK/nexus"; mkdir -p "$FAKE/monitor" "$FAKE/config" "$WORK/state" "$WORK/ghstate" "$WORK/bodies"
cp "$NG_REAL" "$FAKE/monitor/ng"
cp "$(dirname "$NG_REAL")/_bookkeeping.sh" "$(dirname "$NG_REAL")/_nexus-root.sh" "$FAKE/monitor/"
NG="$FAKE/monitor/ng"
printf 'case "${1:-}" in github.repo) printf %s ;; github.user_login) printf test-user ;; *) exit 2 ;; esac\n' "'o/r'" > "$FAKE/config/load.sh"; chmod +x "$FAKE/config/load.sh"
printf 'printf fake-token\n' > "$FAKE/monitor/mint-token.sh"; chmod +x "$FAKE/monitor/mint-token.sh"
# the author verifier: vouches unless MOCK_AUTHOR_FAIL names the comment id
cat > "$FAKE/monitor/assert-bot-author.sh" <<'V'
#!/usr/bin/env bash
[[ "$1" == *"comment-${MOCK_AUTHOR_FAIL:-none}" ]] && exit 1
exit 0
V
chmod +x "$FAKE/monitor/assert-bot-author.sh"
STUB="$WORK/bin"; mkdir -p "$STUB"; CAPTURE="$WORK/gh-calls.txt"
cat > "$STUB/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NG_CAPTURE"
[[ "${1:-}" == "api" ]] || exit 0; shift
method=GET; endpoint=""
while (( $# > 0 )); do case "$1" in -X) method="$2"; shift 2;; -H|-f|--input) shift 2;; /*) endpoint="$1"; shift;; *) shift;; esac; done
[ -t 0 ] || cat >/dev/null 2>&1 || true
n=$(sed -E 's|.*/issues/([0-9]+).*|\1|' <<<"$endpoint")
case "$endpoint" in
    */issues/*/comments) printf '{"html_url":"https://mock/comment-%s"}' "$n" ;;
    */issues/*)
        if [[ "$method" == PATCH ]]; then
            # MOCK_SKIP_CLOSE: the API "accepts" and changes nothing (#1444's silent skip)
            [[ " ${MOCK_SKIP_CLOSE:-} " == *" $n "* ]] || printf closed > "$NG_GHSTATE/$n"
            printf '{"state":"closed"}'
        else
            printf '{"state":"%s"}' "$(cat "$NG_GHSTATE/$n" 2>/dev/null || echo open)"
        fi ;;
    *) printf '{}' ;;
esac
STUB
chmod +x "$STUB/gh"
run_ng() { local _o="$1" _e="$2" _r="$3"; shift 3; local o e r; o=$(mktemp); e=$(mktemp); : > "$CAPTURE"
    ( cd "$WORK" && env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME NEXUS_STATE_DIR="$WORK/state" NG_CAPTURE="$CAPTURE" NG_GHSTATE="$WORK/ghstate" PATH="$STUB:$PATH" "$NG" "$@" ) >"$o" 2>"$e"; r=$?
    printf -v "$_o" '%s' "$(<"$o")"; printf -v "$_e" '%s' "$(<"$e")"; printf -v "$_r" '%s' "$r"; rm -f "$o" "$e"; }
for n in 11 12 13; do printf 'Closed by __PR__ (merge __MERGE__). a__b table cell.\n' > "$WORK/bodies/$n.md"; done
echo "=== every close verified by a direct per-issue read ==="
run_ng out err rc close-set --bodies "$WORK/bodies" --pr 99 --merge abc123 --repo o/r 11 12 13
assert_eq "all three closed → rc 0" "$rc" "0"
assert_contains "the CLOSED set is printed as a SET" "$out" "CLOSED SET (3): 11 12 13"
assert_contains "the NOT-CLOSED set is printed even when empty" "$out" "NOT-CLOSED SET (0):"
assert_eq "the placeholder guard is an exact TOKEN — a__b in an evidence cell does not skip the issue" "$(grep -c 'issues/1[123]/comments' "$CAPTURE")" "3"
assert_eq "…and __PR__ / __MERGE__ were substituted" "$(grep -c '__PR__\|__MERGE__' "$CAPTURE")" "0"
echo "=== a close the API silently skipped is NOT counted closed ==="
rm -f "$WORK/ghstate"/*
MOCK_SKIP_CLOSE=12 run_ng out err rc close-set --bodies "$WORK/bodies" --pr 99 --merge abc123 --repo o/r 11 12 13
assert_eq "one silently-skipped close → rc 1" "$rc" "1"
assert_contains "the NOT-CLOSED set NAMES the member" "$out" "NOT-CLOSED SET (1): 12"
assert_contains "…and the closed set is the other two" "$out" "CLOSED SET (2): 11 13"
echo "=== an unfilled placeholder refuses THAT issue only ==="
rm -f "$WORK/ghstate"/*; printf 'see __TODO__ later\n' > "$WORK/bodies/13.md"
run_ng out err rc close-set --bodies "$WORK/bodies" --pr 99 --merge abc123 --repo o/r 11 13
assert_contains "the unfilled token is named" "$out" "unfilled placeholder token __TODO__"
assert_contains "the other issue still closes" "$out" "CLOSED SET (1): 11"
assert_eq "…and nothing was posted for the refused one" "$(grep -c 'issues/13/comments' "$CAPTURE")" "0"
echo "=== an operator-authored comment is not a close ==="
rm -f "$WORK/ghstate"/*; printf 'body\n' > "$WORK/bodies/13.md"
MOCK_AUTHOR_FAIL=11 run_ng out err rc close-set --bodies "$WORK/bodies" --pr 99 --merge abc123 --repo o/r 11 13
assert_contains "assert-bot-author refusing → NOT-CLOSED, and it says why" "$out" "did NOT vouch for its author"
assert_contains "…without closing that issue" "$out" "NOT-CLOSED SET (1): 11"
echo "=== --only-verify re-reads without posting (repair a member, never re-run the loop) ==="
run_ng out err rc close-set --only-verify --repo o/r 11 13
assert_eq "no comment POSTs under --only-verify" "$(grep -c '/comments' "$CAPTURE")" "0"
assert_contains "…and the verified state is reported" "$out" "CLOSED SET (1): 13"
echo "=== --dry-run posts nothing ==="
run_ng out err rc close-set --dry-run --bodies "$WORK/bodies" --pr 1 --merge x --repo o/r 11
assert_eq "dry-run makes no API call" "$(grep -c 'api' "$CAPTURE")" "0"
assert_contains "dry-run says so" "$out" "DRY-RUN: nothing was posted or closed"
th_summary_and_exit
