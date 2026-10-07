#!/usr/bin/env bash
# test-svc-url-warning.sh — `svc.sh status` WARNS when a registered service's
# healthcheck probes HTTP but its URL cell would render `-`
# (your-org/nexus-code#1742).
#
# The 2026-10-05 shape: a permanent HTTP service registered with a SCRIPT
# healthcheck (`tools/healthcheck.sh`, curling :8774) and no
# `<workdir>/.deploy/endpoint` rendered `-` in the URL column, and nothing told
# its author that either URL convention existed. Driven END TO END through
# `svc.sh status` against a fixture registry, with a private TMUX_TMPDIR so no
# live board is read. Every fixture healthcheck `exit`s BEFORE its curl text,
# so the predicate sees an HTTP probe while nothing touches a real port.
#
# Cases and why:
#   W1  script curls a port, no declaration   → WARN naming the service and the
#                                                 .deploy/endpoint path (the bug)
#   W2  inline `curl localhost:PORT` (no scheme) → WARN: curl, but no URL text
#   N1  the W1 service WITH .deploy/endpoint   → no WARN, URL rendered
#   N2  URL named in the healthcheck text      → no WARN (the old convention)
#   N3  a non-HTTP script healthcheck          → no WARN (the predicate is not
#                                                 "every script")
#   N4  a labsh JupyterLab row (jupyter-health.sh shape: a curl script, the URL
#       from .jupyter/labsh-service.env)        → no WARN: the cell SHOWS a URL
#       (live false positive on the primary, 2026-10-06; the WARN asked
#       svc_endpoint alone while the cell asks svc_jupyter_url first)
#   N5  an SSH port check over /dev/tcp (remote-ssh-health.sh shape) → no WARN:
#       a TCP connect is not HTTP (live false positive, nexus-remote-ssh)
#   W3  an HTTP request line written over /dev/tcp → WARN: still HTTP
#   R   the warning is STDERR-only: stdout table and exit code are identical
#       with and without a warning row

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SVC="$_dir/../svc.sh"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/root/monitor/.state" "$W/tmx"

mksvc() {   # <name> <healthcheck-script-body or ''>
    mkdir -p "$W/$1/tools"
    if [[ -n "$2" ]]; then
        printf '#!/bin/sh\n%s\n' "$2" > "$W/$1/tools/healthcheck.sh"
        chmod +x "$W/$1/tools/healthcheck.sh"
    fi
}
run_status() {   # <registry> → sets OUT ERR RC
    local o="$W/out" e="$W/err"
    env -u TMUX TMUX_TMPDIR="$W/tmx" NEXUS_ROOT="$W/root" NEXUS_SERVICES_REGISTRY="$1" \
        timeout 120 bash "$SVC" status > "$o" 2> "$e"
    RC=$?
    OUT=$(<"$o"); ERR=$(<"$e")
}

mksvc w1 'exit 0
curl -fsS http://localhost:1/healthz >/dev/null'
mksvc n1 'exit 0
curl -fsS http://localhost:1/healthz >/dev/null'
mkdir -p "$W/n1/.deploy"; printf 'http://localhost:1/\n' > "$W/n1/.deploy/endpoint"
mksvc n3 'exit 0
pgrep -f some-daemon >/dev/null'
mksvc w2 ''
mksvc n2 ''
mksvc n4 'exit 0
curl -fsSk -o /dev/null --max-time 3 "$scheme://127.0.0.1:$port/api/status"'
mkdir -p "$W/n4/.jupyter"; printf 'PORT=1\nSCHEME=http\n' > "$W/n4/.jupyter/labsh-service.env"
mksvc n5 'exit 0
{ exec 3<>"/dev/tcp/$0/$1"; } 2>/dev/null || exit 9'
mksvc w3 'exit 0
exec 3<>/dev/tcp/127.0.0.1/1; printf "GET / HTTP/1.0\r\n\r\n" >&3'

printf '%s\t%s\t%s\t%s\n' \
    w1svc "$W/w1" 'echo run' 'tools/healthcheck.sh' \
    w2svc "$W/w2" 'echo run' 'curl -fsS localhost:1/ >/dev/null || true' \
    n1svc "$W/n1" 'echo run' 'tools/healthcheck.sh' \
    n2svc "$W/n2" 'echo run' 'curl -fsS http://localhost:1/ >/dev/null || true' \
    n3svc "$W/n3" 'echo run' 'tools/healthcheck.sh' \
    n4svc "$W/n4" "$W/n4/labsh-supervised.sh" 'tools/healthcheck.sh' \
    n5svc "$W/n5" 'echo run' 'tools/healthcheck.sh' \
    w3svc "$W/w3" 'echo run' 'tools/healthcheck.sh' \
    > "$W/reg-all"

echo '=== #1742: svc.sh status warns on an HTTP service with no derivable URL ==='
run_status "$W/reg-all"
assert_contains     "W1 script healthcheck curling a port, no declaration → WARN" "$ERR" "WARN service w1svc probes HTTP but shows no URL"
assert_contains     "W1 …and names where to declare it"         "$ERR" "$W/w1/.deploy/endpoint"
assert_contains     "W2 inline curl with no URL text → WARN"     "$ERR" "WARN service w2svc probes HTTP"
assert_not_contains "N1 declared .deploy/endpoint → no WARN"    "$ERR" "service n1svc"
assert_contains     "N1 …and its URL IS rendered ON ITS OWN ROW (host may be rewritten; the port is the service's)" \
                    "$(grep -E '^ *[0-9-]+ +n1svc ' <<<"$OUT")" ":1/"
assert_not_contains "N2 URL in the healthcheck text → no WARN"   "$ERR" "service n2svc"
assert_not_contains "N3 non-HTTP script healthcheck → no WARN"   "$ERR" "service n3svc"
assert_not_contains "N4 a JupyterLab row whose cell derives its URL → no WARN" "$ERR" "service n4svc"
assert_not_contains "N5 an SSH port check over /dev/tcp is not HTTP → no WARN" "$ERR" "service n5svc"
assert_contains     "W3 an HTTP request line over /dev/tcp → WARN" "$ERR" "WARN service w3svc probes HTTP"
assert_eq           "exactly three warnings (W1, W2, W3)"        "$(grep -c 'probes HTTP but shows no URL' <<<"$ERR")" "3"

echo '=== the warning is stderr-only: table and exit code unchanged ==='
rc_with=$RC
out_with=$(grep -E '^ *[0-9-]+ +(w1svc|n1svc) ' <<<"$OUT")
printf '%s\t%s\t%s\t%s\n' n1svc "$W/n1" 'echo run' 'tools/healthcheck.sh' > "$W/reg-quiet"
printf '%s\t%s\t%s\t%s\n' w1svc "$W/w1" 'echo run' 'tools/healthcheck.sh' >> "$W/reg-quiet"
mkdir -p "$W/w1/.deploy"; printf 'http://localhost:2/\n' > "$W/w1/.deploy/endpoint"
run_status "$W/reg-quiet"
assert_eq           "R exit code identical with and without a warning" "$RC" "$rc_with"
assert_not_contains "R once declared, the W1 service no longer warns"   "$ERR" "probes HTTP but shows no URL"
assert_eq           "R the stdout table carries no WARN line"           "$(grep -c 'WARN' <<<"$out_with$OUT")" "0"

# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, count=exact).
EXPECTED=14
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
