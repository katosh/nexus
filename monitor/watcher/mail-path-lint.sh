#!/usr/bin/env bash
# mail-path-lint.sh — ONE PATH for outbound email (your-org/nexus-code#1663).
#
# The operator's rule (2026-09-28): "the nexus can send emails without
# impersonating the operator, and exclusively to the operator." Both halves are
# enforced inside `monitor/notify.sh` (THE MAIL POLICY in its header). That
# enforcement is worth nothing if a second file can open its own connection to
# a mail relay, so this lint fails when any file other than `monitor/notify.sh`
# carries a mail-sending construct.
#
# Usage:  bash monitor/watcher/mail-path-lint.sh [--files] [<repo-root>]
#   default   one row per site: <file>:<line>:<text>; exit 1 if any
#   --files   the POPULATION, one path per line (the guard index reads this)
#
# Exit: 0 clean · 1 a mail-sending site outside the sanctioned path ·
#       3 REFUSED — the population could not be built (never a green) ·
#       4 a reviewed exemption no longer matches any line (stale: re-review)
#
# THE POPULATION is every file git can see in <repo-root>: TRACKED plus
# UNTRACKED-not-ignored (`ls-files -co --exclude-standard`), so a new file is
# caught before it is committed. Every extension, documentation included — a
# skill page showing a runnable mail command is an instruction an agent will
# follow. Binary files are skipped (`grep -I`).
#
# NOTHING IS STRIPPED. Comments and heredoc bodies are scanned as written:
# notify.sh's own sender lives in a heredoc, so a stripper would blind this
# lint to exactly the shape it exists for. The cost is that PROSE naming a mail
# tool is a hit too; each such line is a reviewed row in
# `mail-path-lint.allow` (<path> TAB <line prefix> TAB <reason>), matched by the
# line's text after leading whitespace, and a row that matches nothing is
# itself a failure (exit 4) so the exemption list cannot rot into a hole.
#
# THE CONSTRUCTS (ERE, the PAT lines below). Each pattern is written so this
# file does not match itself — a bracketed letter breaks the literal — and the
# suite plants every family in its literal form (test-mail-path-lint.sh). In
# words: the python SMTP module (any prefix) and its client class constructor;
# the classic submission binaries and clients; the one-line mail command with a
# subject flag, or with an address argument; SMTP URL schemes (curl); a raw
# socket to a submission port (bash /dev/tcp, netcat and friends, a TLS
# client, a python socket connect); a raw SMTP dialogue in ANY case (SMTP
# verbs are case-insensitive, and the python SMTP module itself sends them
# lowercase); the perl/ruby SMTP classes; git's patch mailer; the node mail library.
#
# BOUNDARY — A SOURCE-TEXT LINT CANNOT PROVE THERE IS NO MAIL PATH. It
# catches the KNOWN constructs above, each planted as a positive control in the
# suite, and nothing more. It cannot see a construct assembled at runtime (a
# module name built by concatenation, a port held in a variable), a relay
# reached through a language or client this list does not name, a file outside
# this repository's git-visible set (work/, reports/, ignored files, other
# repos), or a command an agent types into a shell. A skeptic pass on
# your-org/nexus-code#1664 measured 7 of 9 planted evasions passing the first
# version; the ones it named are covered now, and the class is not closed. The
# binding control is the policy inside notify.sh; this lint keeps a SECOND path
# from arriving by ordinary authorship.
set -uo pipefail

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE=scan
ROOT=""
for a in "$@"; do
    case "$a" in
        --files) MODE=files ;;
        -*) printf 'mail-path-lint: unknown flag %s\n' "$a" >&2; exit 2 ;;
        *) ROOT="$a" ;;
    esac
done
ROOT="${ROOT:-$(cd "$_dir/../.." && pwd)}"

SANCTIONED="monitor/notify.sh"
ALLOW_REL="monitor/watcher/mail-path-lint.allow"

PAT='smtp[l]ib'
PAT+='|\bSMT[P](_SSL)?[[:space:]]*[(]'
PAT+='|\bsend[m]ail\b|\bmail[x]\b|\b[ms]smt[p]\b|\bswak[s]\b|\bmut[t]\b|\bs-nai[l]\b'
PAT+='|\bmai[l][[:space:]]+(-[[:alpha:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)*-s\b'
PAT+='|smtps?:[/]/'
PAT+='|/dev/(tcp|udp)/[^/[:space:]]+/(25|465|587)\b'
PAT+='|\b(n[c]|nca[t]|netca[t]|soca[t]|telne[t]|openss[l][[:space:]]+s_client)\b.*\b(25|465|587)\b'
PAT+='|([Mm][Aa][Ii][Ll][[:space:]]+[Ff][Rr][Oo][Mm]|[Rr][Cc][Pp][Tt][[:space:]]+[Tt][Oo])[[:space:]]*:'
PAT+='|Net::SMT[P]|\bsend-emai[l]\b|\bnodemaile[r]\b'
PAT+='|\bmai[l][[:space:]]+([^|;&[:space:]]+[[:space:]]+)*[^|;&[:space:]@]+@[[:alnum:]-]+\.[[:alnum:].-]+'
PAT+='|\b(create_connectio[n]|\.connec[t])[[:space:]]*[(][^)]*\b(25|465|587)\b'

# The population must be about ROOT itself, never an enclosing repository
# (git -C walks up — CLAUDE.md REPO-WALKUP).
_top=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || _top=""
if [[ -z "$_top" || "$(cd "$_top" && pwd -P)" != "$(cd "$ROOT" && pwd -P)" ]]; then
    printf 'mail-path-lint: REFUSED — %s is not the root of its own git repository; I cannot build the population.\n' "$ROOT" >&2
    exit 3
fi
cd "$ROOT" || exit 3

_scratch=$(mktemp -d) || { printf 'mail-path-lint: REFUSED — no scratch dir.\n' >&2; exit 3; }
trap 'rm -rf "$_scratch"' EXIT

if ! git ls-files -co --exclude-standard -z > "$_scratch/pop0"; then
    printf 'mail-path-lint: REFUSED — git ls-files failed; a population I could not build certifies nothing.\n' >&2
    exit 3
fi
# Regular files only: a tracked SYMLINK (e.g. a skills dir link) is read at its
# target's own path, and a tracked file deleted from the worktree has nothing
# to read. Neither is a file this lint could certify.
: > "$_scratch/pop"
while IFS= read -r -d '' f; do
    [[ -f "$f" && ! -L "$f" ]] && printf '%s\n' "$f" >> "$_scratch/pop"
done < "$_scratch/pop0"
tr '\n' '\0' < "$_scratch/pop" > "$_scratch/pop0"
if [[ ! -s "$_scratch/pop" ]]; then
    printf 'mail-path-lint: REFUSED — the population is EMPTY.\n' >&2
    exit 3
fi

if [[ "$MODE" == files ]]; then
    cat "$_scratch/pop"
    exit 0
fi

# grep through xargs execs the PROGRAM, so no shell grep wrapper (ugrep,
# .gitignore-honouring) is in play (CLAUDE.md #618/#707). rc 1 from a batch is
# "no match"; >1 is an error and must not be read as a clean batch.
xargs -0 -r grep -nIHE -e "$PAT" -- < "$_scratch/pop0" > "$_scratch/raw" 2> "$_scratch/err"
_grc=$?
# xargs reports 123 when any grep invocation exited 1–125: that includes the
# ordinary "no match" rc 1, so a real error is recognised by stderr instead.
if (( _grc != 0 && _grc != 123 )) || [[ -s "$_scratch/err" ]]; then
    printf 'mail-path-lint: REFUSED — the scan errored (xargs rc %s):\n' "$_grc" >&2
    sed 's/^/  /' "$_scratch/err" >&2
    exit 3
fi

# Reviewed exemptions: path TAB prefix TAB reason; `#` lines are comments.
: > "$_scratch/allow"
if [[ -f "$ALLOW_REL" ]]; then
    grep -v -e '^#' -e '^[[:space:]]*$' -- "$ALLOW_REL" > "$_scratch/allow" || true
fi

# The allow file is read in BEGIN, never by the `FNR == NR` idiom: with an
# EMPTY allow file that idiom reads the SCAN RESULTS as exemption rows
# (measured here — every hit became a "malformed exemption", rc 3).
awk -v allowf="$_scratch/allow" -v sanctioned="$SANCTIONED" -v used="$_scratch/used" '
    BEGIN {
        while ((r = (getline row < allowf)) > 0) {
            m = split(row, f, "\t")
            if (m < 3 || f[1] == "" || f[2] == "") { printf "mail-path-lint: malformed exemption row: %s\n", row > "/dev/stderr"; bad = 1; continue }
            n++; ap[n] = f[1]; apre[n] = f[2]
        }
        if (r < 0) { print "mail-path-lint: could not read the allow file" > "/dev/stderr"; bad = 1 }
    }
    {
        # grep -nH: <path>:<line>:<text>. Paths here carry no colon (git-tracked
        # names in this repo); split on the first two.
        i = index($0, ":"); path = substr($0, 1, i - 1); rest = substr($0, i + 1)
        j = index(rest, ":"); ln = substr(rest, 1, j - 1); text = substr(rest, j + 1)
        if (path == sanctioned) next
        t = text; sub(/^[[:space:]]+/, "", t)
        for (k = 1; k <= n; k++)
            if (ap[k] == path && substr(t, 1, length(apre[k])) == apre[k]) { hit[k]++; next }
        print path ":" ln ":" text
    }
    END {
        for (k = 1; k <= n; k++) if (!hit[k]) print ap[k] "\t" apre[k] > used
        exit bad
    }' "$_scratch/raw" > "$_scratch/hits"
_arc=$?
if (( _arc != 0 )); then
    printf 'mail-path-lint: REFUSED — %s is malformed.\n' "$ALLOW_REL" >&2
    exit 3
fi

_rc=0
if [[ -s "$_scratch/hits" ]]; then
    cat "$_scratch/hits"
    printf '\nmail-path-lint: %d mail-sending site(s) outside %s.\n' "$(wc -l < "$_scratch/hits")" "$SANCTIONED" >&2
    printf '  The nexus emails the operator ONLY and never AS the operator, and that is\n' >&2
    printf '  enforced in exactly one place: send through monitor/notify.sh --priority\n' >&2
    printf '  emergency. If a hit is prose, not a sender, add a reviewed row to %s.\n' "$ALLOW_REL" >&2
    _rc=1
fi
if [[ -s "$_scratch/used" ]]; then
    printf 'mail-path-lint: STALE exemption(s) in %s — they match no line; remove or re-review:\n' "$ALLOW_REL" >&2
    sed 's/^/  /' "$_scratch/used" >&2
    (( _rc == 0 )) && _rc=4
fi
exit "$_rc"
