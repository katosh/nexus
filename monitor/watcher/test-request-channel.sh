#!/usr/bin/env bash
# Tests for monitor/request-channel.sh — the request inbox + bidirectional
# request/reply protocol (agent-channel RFC Part B/D).
#
# Covers:
#   1.  file: writes .new.md, prints id == on-disk stem, frontmatter shape
#   2.  file: rejects an invalid --origin (spoof-proof, filename-safe)
#   3.  collision-free id: same ts+origin+slug → distinct ids via the
#       mkdir reservation + numeric disambiguator; every printed id has a
#       matching on-disk stem (printed id ≡ on-disk stem)
#   4.  round-trip: file → claim → reply → await reads the ## Reply (rc 0)
#   5.  reply correlation: reply: frontmatter carries worker/dir/issue refs
#   6.  reply-twice refused (one reply per request; non-zero, no torn file)
#   7.  ack: .claimed → .done; idempotent on an already-terminal id (rc 0)
#   8.  fail: → .failed with the reason recorded
#   9.  await exit-code map: replied=0, done=0, failed=2, pending=4
#   10. fetch: path-confined to replies/<id>/{progress,results}.md;
#       not-ready results → rc 3; bad selector / traversal id refused
#   10b. fetch results on a replied request returns the RAW body (rc 0, no
#       markdown envelope) — the raw-bytes transport; progress on a replied
#       request is a terminal rc-0 pointer, not "no progress"
#   10c. --reply optional|none accepted as a no-op (== the default);
#       a bogus --reply value still refused
#   10d. reply body round-trips BYTE-EXACT (sha) through BOTH the write path
#       (on-disk) AND the emit path (fetch results raw + await envelope): a
#       body full of backslashes, escapes (\n \t \\ \"), and braces survives
#       — the awk -v escape-mangling regression
#   11. ownership: await/fetch verify origin == principal (cross-client deny, rc 5)
#   12. no-publish: reply materializes results INTO the reply dir; fetch reads it
#   13. ack-vs-claim race (D5): the watcher's claim interposes mid-ack → ack
#       re-resolves from .claimed and succeeds idempotently (no spurious die)
#   14. reply-vs-reaper race (D5): the max-age reaper interposes before reply
#       secures the slot → reply fails LOUDLY (rc6), the reaper's .failed file is
#       byte-intact (claim-first never wrote to it), no reply text stranded, no
#       results.md leaked
#   15. transitional-read race (D5): a reply interposes between fetch's resolve
#       and its ownership read → one re-resolve, no spurious rc5; ownership still
#       enforced against a foreign principal after the re-resolve
#   16. reply --amend: refuses from every non-replied state (rc6); on a replied
#       request updates the body byte-exact (sha, on-disk + fetch), stamps
#       amended_at, keeps a single reply: block + ## Reply, preserves the request
#   17. F1 crash-safety: a content transition claims a NON-AUTHORITATIVE
#       intermediate (.replying), so a crash between the claim and the content
#       swap (17a) or between the swap and the finalize (17b) leaves an
#       intermediate — NEVER a partial terminal. No reader false-succeeds
#       (await rc4, fetch status→claimed, fetch results→rc3); the watcher reaper
#       recovers (incomplete .replying→.failed; complete .replying→.replied
#       byte-exact through crash+recovery).
#   18. amend with reply-body ## Reply / reply: lookalikes amends byte-exact,
#       no leaked fragment, no duplicate header.
#   19. ROUND-3 BLOCKER-1: a request whose ## Details quotes ## Reply / state:
#       replied, MIDGAP-crashed → the reaper keys completeness on FRONTMATTER
#       (state: new) and sends it to .failed, never a false .replied.
#   20. ROUND-3 BLOCKER-2: a request whose ## Details quotes ## Reply — amend
#       keys the body boundary on the unforgeable body_bytes marker (last N
#       bytes), so the request tail survives byte-exact (no data loss). 20b:
#       amend REFUSES a legacy reply with no body_bytes marker. 20c: the legacy
#       fetch-results fallback REFUSES an ambiguous ## Reply rather than guess.
#   21. list surfaces the .replying/.failing content-transition intermediates:
#       selected by --state claimed (the reader rule) and --state all, rendered
#       with the LITERAL state word ([replying]/[failing]); excluded from every
#       other stable-state selector; the --state enum itself is unchanged
#       (--state replying → rc1); fetch status still maps them to `claimed`.
#
# Concurrency / crash seams (all fire ONCE; mirror CHAN_TS_OVERRIDE):
#   CHAN_TRANSITION_RACE_HOOK      resolve↔claim
#   CHAN_TRANSITION_MIDGAP_HOOK    claim↔content-mv     (crash-sim via `exit`)
#   CHAN_TRANSITION_FINALIZE_HOOK  content-mv↔finalize  (crash-sim via `exit`)
#   CHAN_READ_RACE_HOOK            fetch resolve↔ownership-read
#
# Run: bash monitor/watcher/test-request-channel.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_test_dir/.." && pwd)
RC="$_monitor_dir/request-channel.sh"

PASS=0; FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — missing %q\n    in: <<%s>>\n' "$label" "$needle" "$hay" >&2; FAIL=$((FAIL+1)); fi
}
assert_rc() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — rc %s want %s\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}
assert_file() {
    local label="$1" f="$2"
    if [[ -f "$f" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — no file %q\n' "$label" "$f" >&2; FAIL=$((FAIL+1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_STATE_DIR="$WORK/state"
mkdir -p "$NEXUS_STATE_DIR"
REQ="$NEXUS_STATE_DIR/requests"

# Helper: simulate the watcher's claim (atomic .new → .claimed).
_claim() { local id="$1"; mv "$REQ/$id.new.md" "$REQ/$id.claimed.md"; }

echo "== 1. file: id == on-disk stem, frontmatter =="
id=$("$RC" file --origin worker-foo --kind spawn-skeptic --slug review-x \
        --reply required --message "Spawn a skeptic for foo.")
assert_file "id1 .new.md exists (printed id == stem)" "$REQ/$id.new.md"
body=$("$RC" show "$id")
assert_contains "frontmatter request id" "$body" "request: $id"
assert_contains "frontmatter origin"     "$body" "origin: worker-foo"
assert_contains "frontmatter kind"       "$body" "kind: spawn-skeptic"
assert_contains "frontmatter reply"      "$body" "reply: required"
assert_contains "Request section body"   "$body" "Spawn a skeptic for foo."

echo "== 2. file: invalid origin rejected =="
"$RC" file --origin 'bad origin!' --kind question --slug s --message x >/dev/null 2>&1
assert_rc "invalid origin → die rc1" "$?" "1"

echo "== 3. collision-free id (deterministic same-second) =="
export CHAN_TS_OVERRIDE=20260629T000000Z
a=$("$RC" file --origin alice --kind question --slug dup --message "one")
b=$("$RC" file --origin alice --kind question --slug dup --message "two")
c=$("$RC" file --origin alice --kind question --slug dup --message "three")
unset CHAN_TS_OVERRIDE
assert_eq  "first id is the bare stem"      "$a" "20260629T000000Z-alice-dup"
assert_eq  "second id disambiguated -01"    "$b" "20260629T000000Z-alice-dup-01"
assert_eq  "third id disambiguated -02"     "$c" "20260629T000000Z-alice-dup-02"
assert_file "id a on disk" "$REQ/$a.new.md"
assert_file "id b on disk" "$REQ/$b.new.md"
assert_file "id c on disk" "$REQ/$c.new.md"
# distinctness
[[ "$a" != "$b" && "$b" != "$c" && "$a" != "$c" ]]
assert_rc "three ids are distinct" "$?" "0"

echo "== 4-5. round-trip: file → claim → reply → await =="
rid=$("$RC" file --origin remote-alice --kind question --slug sum --reply required --message "Summarize foo")
_claim "$rid"
"$RC" reply "$rid" --worker foo-sum --dir /work/foo-sum --issue your-org/your-nexus#412 \
        --message "Spawned foo-sum; tracking the issue." >/dev/null
assert_file "reply renamed to .replied.md" "$REQ/$rid.replied.md"
out=$("$RC" await "$rid" --timeout 0); arc=$?
assert_rc       "await on replied → rc 0" "$arc" "0"
assert_contains "await prints ## Reply"   "$out" "## Reply"
assert_contains "reply: status spawned"   "$out" "status: spawned"
assert_contains "reply: worker window"    "$out" "window: foo-sum"
assert_contains "reply: worker directory" "$out" "directory: /work/foo-sum"
assert_contains "reply: github_issue"     "$out" "github_issue: your-org/your-nexus#412"
assert_contains "reply: state replied"    "$out" "state: replied"

echo "== 6. reply-twice refused =="
"$RC" reply "$rid" --message "second reply" >/dev/null 2>&1
assert_rc "second reply refused rc6" "$?" "6"

echo "== 7. ack idempotency =="
aid=$("$RC" file --origin w --kind question --slug ackme --message body)
_claim "$aid"
"$RC" ack "$aid" >/dev/null; r1=$?
assert_file "ack → .done.md" "$REQ/$aid.done.md"
"$RC" ack "$aid" >/dev/null 2>&1; r2=$?
assert_rc "first ack rc0"  "$r1" "0"
assert_rc "double-ack rc0 (idempotent)" "$r2" "0"

echo "== 8. fail =="
fid=$("$RC" file --origin w --kind question --slug failme --message body)
_claim "$fid"
"$RC" fail "$fid" --reason "malformed target window" >/dev/null
assert_file "fail → .failed.md" "$REQ/$fid.failed.md"
assert_contains "failure reason recorded" "$(cat "$REQ/$fid.failed.md")" "malformed target window"
# Escape-fidelity regression: a reason carrying \n, \t, \\ literals must land
# VERBATIM. Pre-fix, cmd_fail piped the reason through `awk -v reason=`, whose
# backslash-escape processing turned the two-char sequence \n into a real
# newline (and \t, \\ likewise) — free prose silently mangled (#401 class).
fid2=$("$RC" file --origin w --kind question --slug failesc --message body)
_claim "$fid2"
"$RC" fail "$fid2" --reason 'path C:\new\table, regex \\d+ end' >/dev/null
assert_contains "failure reason escape-verbatim" "$(cat "$REQ/$fid2.failed.md")" 'path C:\new\table, regex \\d+ end'

echo "== 9. await exit-code map =="
# pending (claimed, not replied) → rc 4
pid=$("$RC" file --origin w --kind question --slug pend --message body); _claim "$pid"
"$RC" await "$pid" --timeout 0 >/dev/null 2>&1; assert_rc "await pending → rc4" "$?" "4"
# done → rc 0
"$RC" ack "$pid" >/dev/null
"$RC" await "$pid" --timeout 0 >/dev/null 2>&1; assert_rc "await done → rc0" "$?" "0"
# failed → rc 2
"$RC" await "$fid" --timeout 0 >/dev/null 2>&1; assert_rc "await failed → rc2" "$?" "2"

echo "== 10. fetch path-confinement =="
"$RC" fetch "$rid" ../../etc/passwd >/dev/null 2>&1; assert_rc "fetch bad selector → rc1" "$?" "1"
"$RC" fetch "../../../etc/passwd" results >/dev/null 2>&1; assert_rc "traversal id → rc1" "$?" "1"
# not-ready path: a CLAIMED (not yet replied) request has no results.md yet.
nr=$("$RC" file --origin w --kind question --slug notready --message body); _claim "$nr"
"$RC" fetch "$nr" results >/dev/null 2>&1; assert_rc "fetch results not-ready (claimed) → rc3" "$?" "3"

echo "== 10b. ISSUE B + raw transport: fetch results on a replied request returns the RAW body =="
# $rid is replied with publish=true. cmd_reply now materializes results.md as
# the RAW reply body (no markdown envelope), so `fetch results` is a
# corruption-proof raw-bytes pull — resolving ISSUE B (no more "not ready"
# after state=replied) and giving a byte-exact transport.
fout=$("$RC" fetch "$rid" results); frc=$?
assert_rc       "fetch results on replied → rc0"          "$frc" "0"
assert_contains "fetch results returns the raw body"      "$fout" "Spawned foo-sum; tracking the issue."
# It is the RAW payload, NOT the markdown envelope (no frontmatter / headers).
grep -q '^## Reply$' <<<"$fout" && assert_rc "fetch results is raw body, not the envelope" 1 0 \
                               || assert_rc "fetch results is raw body, not the envelope" 0 0
grep -q '^request:' <<<"$fout"  && assert_rc "fetch results omits frontmatter" 1 0 \
                               || assert_rc "fetch results omits frontmatter" 0 0
# The same body is still readable in full via the await envelope.
awaitout=$("$RC" await "$rid" --timeout 0)
assert_contains "await envelope carries the same body" "$awaitout" "Spawned foo-sum; tracking the issue."
# progress on a replied request is a terminal, successful state (rc0), not "no progress".
pgout=$("$RC" fetch "$rid" progress); pgrc=$?
assert_rc       "fetch progress on replied → rc0"       "$pgrc" "0"
assert_contains "fetch progress points at the result"   "$pgout" "state=replied"

echo "== 10s. fetch status: read-only rename-state, ownership-checked, no new verb =="
# The client-side watcher (nexus-request) observes ACTIVE PROCESSING via a
# read-only `fetch <id> status` sub-mode — it returns ONLY the rename-state
# word of the client's OWN request (RFC §2.8, the rename-as-progress design).
sid=$("$RC" file --origin remote-carol --kind question --slug statechk --reply required --message "watch my state")
sstat=$("$RC" fetch "$sid" status --principal remote-carol); assert_rc "status new → rc0" "$?" "0"
assert_eq       "status reports 'new' before claim"     "$sstat" "new"
_claim "$sid"
sstat=$("$RC" fetch "$sid" status --principal remote-carol)
assert_eq       "status reports 'claimed' after claim (active processing)" "$sstat" "claimed"
# ownership: a different principal is denied (rc5) — same scoping as await/fetch.
"$RC" fetch "$sid" status --principal remote-mallory >/dev/null 2>&1
assert_rc       "status ownership check denies foreign principal → rc5" "$?" "5"
# a confined principal fetching an unknown id cannot verify ownership → rc5.
"$RC" fetch "no-such-id" status --principal remote-carol >/dev/null 2>&1
assert_rc       "status unknown id (confined) → rc5"    "$?" "5"
# terminal state surfaces too.
"$RC" reply "$sid" --message "here you go" >/dev/null
sstat=$("$RC" fetch "$sid" status --principal remote-carol)
assert_eq       "status reports 'replied' after reply"  "$sstat" "replied"
# status is a strict enum sub-mode of fetch: a bogus selector is still refused.
"$RC" fetch "$sid" statuss --principal remote-carol >/dev/null 2>&1
assert_rc       "bogus selector still refused (rc1)"    "$?" "1"

echo "== 10c. ISSUE C: --reply optional|none accepted as a no-op =="
oid=$("$RC" file --origin w --kind question --slug replyopt --reply optional --message body); orc=$?
assert_rc "file --reply optional → rc0" "$orc" "0"
assert_file "file --reply optional wrote .new.md" "$REQ/$oid.new.md"
# 'optional' is the default (not required): no `reply:` frontmatter line is emitted.
assert_eq "no reply: frontmatter for --reply optional" \
    "$(grep -c '^reply:' "$REQ/$oid.new.md")" "0"
nid2=$("$RC" file --origin w --kind question --slug replynone --reply none --message body); nrc=$?
assert_rc "file --reply none → rc0" "$nrc" "0"
# a bogus --reply value is still refused (die rc1).
"$RC" file --origin w --kind question --slug replybad --reply maybe --message body >/dev/null 2>&1
assert_rc "file --reply maybe (bogus) → rc1" "$?" "1"

echo "== 10d. ISSUE D: reply body round-trips BYTE-EXACT (backslashes/escapes/braces) =="
# The bug: cmd_reply passed the body through `awk -v prose=…`, and awk applies
# backslash-escape processing to a -v value — so \n, \t, \\, \", \{ in a
# script/code/JSON body were silently rewritten (corrupted + byte-shortened).
# The fix appends the body verbatim (cat), never through awk. Assert a body
# full of backslashes + quotes + braces + literal \n reproduces byte-identical.
cat > "$WORK/body.src" <<'BODYEOF'
#!/bin/sh
echo "line with \n and \t sequences"
grep -E '^\d+\{2,\}$' file
printf 'a\\b\n'
json='{"k":"v\n","p":"a\\b","q":"\"x\""}'
regex="^foo\|bar\$"
BODYEOF
sha_src=$(sha256sum < "$WORK/body.src" | cut -d' ' -f1)
dbid=$("$RC" file --origin remote-dave --kind question --slug bodyfidelity --reply required --message "placeholder")
_claim "$dbid"
"$RC" reply "$dbid" --file "$WORK/body.src" --worker w >/dev/null
replied="$REQ/$dbid.replied.md"
assert_file "ISSUE D: reply wrote .replied.md" "$replied"
# Extract the ## Reply body byte-exact: it is everything from 2 lines after the
# "## Reply" header (skip the header + the one blank line) to EOF. tail -n +K
# is a byte-faithful copy from that line onward.
reply_line=$(grep -n '^## Reply$' "$replied" | tail -1 | cut -d: -f1)
tail -n +$((reply_line + 2)) "$replied" > "$WORK/body.out"
sha_out=$(sha256sum < "$WORK/body.out" | cut -d' ' -f1)
assert_eq "ISSUE D: on-disk body sha matches source (write path byte-exact)" "$sha_out" "$sha_src"
assert_contains "ISSUE D: literal backslash-n preserved (not collapsed)" "$(cat "$WORK/body.out")" 'v\n'
assert_contains "ISSUE D: double-backslash preserved"                    "$(cat "$WORK/body.out")" 'a\\b'
# READ/EMIT path: fetch results returns the RAW body bytes — sha must match
# source exactly (this is the client-facing pull; corruption here is the bug
# the client actually saw).
"$RC" fetch "$dbid" results --principal remote-dave > "$WORK/fetch.body"
sha_fetch=$(sha256sum < "$WORK/fetch.body" | cut -d' ' -f1)
assert_eq "ISSUE D: fetch results raw body sha == source (emit byte-exact)" "$sha_fetch" "$sha_src"
# await's envelope carries the body byte-exact too (extract + sha).
"$RC" await "$dbid" --timeout 0 --principal remote-dave > "$WORK/await.full"
al=$(grep -n '^## Reply$' "$WORK/await.full" | tail -1 | cut -d: -f1)
tail -n +$((al + 2)) "$WORK/await.full" > "$WORK/await.body"
sha_await=$(sha256sum < "$WORK/await.body" | cut -d' ' -f1)
assert_eq "ISSUE D: await body sha == source (emit byte-exact)" "$sha_await" "$sha_src"

echo "== 10e. REQUEST-direction body round-trips BYTE-EXACT (## Details) + summary layout =="
# The D3 defect: cmd_file captured the body via `body=$(_chan_read_body …)`, and
# $(…) strips ALL trailing newlines — so a body's exact trailing bytes were lost
# though the docs claimed byte-exactness. The fix streams the body file→file
# (never a shell capture) and assembles ## Details from that file. Assert a body
# with a real TAB, literal backslashes, an embedded newline, AND exactly two
# trailing newlines reproduces byte-identical under ## Details. Falsifiability:
# under the old $(…) capture the two trailing newlines collapse to one, so this
# sha assertion goes RED (proven by transiently reintroducing the defect).
printf 'first line\twith a tab\nmid \\d+ and \\\\ backslashes\nlast\n\n' > "$WORK/reqbody.src"
sha_reqsrc=$(sha256sum < "$WORK/reqbody.src" | cut -d' ' -f1)
rqid=$("$RC" file --origin remote-eve --kind question --slug reqbodyfidelity --reply required --file "$WORK/reqbody.src")
assert_file "10e: request wrote .new.md" "$REQ/$rqid.new.md"
# Extract the ## Details body byte-exact: 2 lines after the "## Details" header
# (skip header + one blank) to EOF. ## Details is the LAST section by design, so
# tail -n +K is a byte-faithful copy of the body from that line onward.
# FIRST match, deliberately: ## Details is the last HEADER, but the body that
# follows it may itself contain a '## Details' line — tail -1 would anchor on
# that body line and mis-extract.
det_line=$(grep -n '^## Details$' "$REQ/$rqid.new.md" | head -1 | cut -d: -f1)
tail -n +$((det_line + 2)) "$REQ/$rqid.new.md" > "$WORK/reqbody.out"
sha_reqout=$(sha256sum < "$WORK/reqbody.out" | cut -d' ' -f1)
assert_eq       "10e: ## Details body sha == source (request byte-exact)" "$sha_reqout" "$sha_reqsrc"
assert_contains "10e: literal double-backslash preserved"                 "$(cat "$WORK/reqbody.out")" 'and \\ backslashes'
# ## Request carries ONLY the first line (the summary the watcher surfaces); the
# full body lives once under ## Details (no double-store). Assert the ## Request
# section has the first line but NOT later body lines.
reqsec=$(awk '/^## Request$/{p=1;next} /^## Details$/{p=0} p' "$REQ/$rqid.new.md")
assert_contains "10e: ## Request carries the first-line summary" "$reqsec" "first line"
grep -q 'last' <<<"$reqsec" && assert_rc "10e: ## Request omits later body lines (no double-store)" 1 0 \
                           || assert_rc "10e: ## Request omits later body lines (no double-store)" 0 0

echo "== 11-12. no-publish: materialize + fetch + ownership =="
np=$("$RC" file --origin remote-bob --kind question --slug np --no-publish --message "no publish")
_claim "$np"
echo "FINAL RESULTS BODY" > "$WORK/results-src.md"
"$RC" reply "$np" --no-publish --results "$WORK/results-src.md" --message "done" >/dev/null
got=$("$RC" fetch "$np" results); assert_rc "fetch results (materialized) rc0" "$?" "0"
assert_contains "fetched results content" "$got" "FINAL RESULTS BODY"
assert_contains "reply: publish false"    "$("$RC" show "$np")" "publish: false"
# ownership: alice cannot read bob's reply
"$RC" fetch "$np" results --principal remote-alice >/dev/null 2>&1
assert_rc "cross-client fetch denied rc5" "$?" "5"
"$RC" await "$np" --timeout 0 --principal remote-alice >/dev/null 2>&1
assert_rc "cross-client await denied rc5" "$?" "5"
# owner can
"$RC" fetch "$np" results --principal remote-bob >/dev/null 2>&1
assert_rc "owner fetch allowed rc0" "$?" "0"

# ── D5 transition-engine: deterministic concurrency via test seams ──────
# CHAN_TRANSITION_RACE_HOOK / CHAN_READ_RACE_HOOK (mirroring CHAN_TS_OVERRIDE)
# interpose a competing rename between a resolve and the following mv/read,
# firing at most once per process so a bounded-retry converges.

echo "== 13. ack-vs-claim race → idempotent success (re-resolve from .claimed) =="
# ack resolves .new, the watcher's claim (.new → .claimed) interposes before
# ack's rename. Pre-fix the mv hard-died (spurious failure); now ack re-resolves
# and completes from .claimed (ack-from-claimed is legal).
arid=$("$RC" file --origin w --kind question --slug ackrace --message body)
CHAN_TRANSITION_RACE_HOOK="mv '$REQ/$arid.new.md' '$REQ/$arid.claimed.md'" \
    "$RC" ack "$arid" >/dev/null 2>&1
assert_rc   "ack survives a mid-ack claim (rc0)"        "$?" "0"
assert_file "ack-vs-claim landed at .done.md"           "$REQ/$arid.done.md"
[[ ! -e "$REQ/$arid.new.md" && ! -e "$REQ/$arid.claimed.md" ]]
assert_rc   "no stray .new/.claimed after the raced ack" "$?" "0"

echo "== 14. reply-vs-reaper race → loud failure, terminal file byte-intact =="
# reply resolves .claimed; the max-age reaper (.claimed → .failed) interposes
# before reply secures the state slot. Claim-first means reply LOSES loudly and
# never writes its text — the reaper's .failed file is byte-for-byte the pre-reply
# claimed content, and no results.md leaks for the failed request.
rrid=$("$RC" file --origin remote-frank --kind question --slug replyrace --reply required --message "the original request")
_claim "$rrid"
claimed_sha=$(sha256sum < "$REQ/$rrid.claimed.md" | cut -d' ' -f1)
CHAN_TRANSITION_RACE_HOOK="mv '$REQ/$rrid.claimed.md' '$REQ/$rrid.failed.md'" \
    "$RC" reply "$rrid" --message "SECRET REPLY TEXT should never land" >/dev/null 2>&1
assert_rc   "reply lost to the reaper → rc6"            "$?" "6"
assert_file "reaper's .failed.md exists"                "$REQ/$rrid.failed.md"
[[ ! -e "$REQ/$rrid.replied.md" ]]; assert_rc "no .replied.md produced by the lost reply" "$?" "0"
failed_sha=$(sha256sum < "$REQ/$rrid.failed.md" | cut -d' ' -f1)
assert_eq   "reaped .failed.md byte-identical to the claimed file (uncorrupted)" "$failed_sha" "$claimed_sha"
grep -q 'SECRET REPLY TEXT' "$REQ/$rrid.failed.md" \
    && assert_rc "no reply text stranded in .failed" 1 0 || assert_rc "no reply text stranded in .failed" 0 0
grep -q '^## Reply$' "$REQ/$rrid.failed.md" \
    && assert_rc "no ## Reply section in .failed" 1 0 || assert_rc "no ## Reply section in .failed" 0 0
[[ ! -e "$REQ/replies/$rrid/results.md" ]]
assert_rc   "no results.md materialized for the lost reply" "$?" "0"

echo "== 15. transitional-read race (c) → one re-resolve, no spurious rc5 =="
# fetch resolves .claimed; the orchestrator's reply (.claimed → .replied)
# interposes before fetch's ownership frontmatter read. Pre-fix the vanished
# .claimed gave an empty origin → spurious rc5; now one re-resolve lands on the
# stable .replied and ownership succeeds.
crid=$("$RC" file --origin remote-gwen --kind question --slug readrace --reply required --message "watch me")
_claim "$crid"
out=$(CHAN_READ_RACE_HOOK="mv '$REQ/$crid.claimed.md' '$REQ/$crid.replied.md'" \
        "$RC" fetch "$crid" status --principal remote-gwen 2>/dev/null); rc=$?
assert_rc   "transitional-read race: not spuriously rejected (rc0)"  "$rc" "0"
assert_eq   "transitional-read race: re-resolved to the stable state" "$out" "replied"
# ownership still enforced after the re-resolve: a foreign principal is denied.
crid2=$("$RC" file --origin remote-gwen --kind question --slug readrace2 --reply required --message "watch me 2")
_claim "$crid2"
CHAN_READ_RACE_HOOK="mv '$REQ/$crid2.claimed.md' '$REQ/$crid2.replied.md'" \
    "$RC" fetch "$crid2" status --principal remote-mallory >/dev/null 2>&1
assert_rc   "transitional-read race: foreign principal still denied (rc5)" "$?" "5"

echo "== 16. reply --amend: refusal matrix + byte-exact round-trip =="
# --amend refuses from every NON-replied state.
am_new=$("$RC" file --origin w --kind question --slug amendnew --message body)
"$RC" reply "$am_new" --amend --message x >/dev/null 2>&1; assert_rc "amend on .new refused (rc6)" "$?" "6"
am_cl=$("$RC" file --origin w --kind question --slug amendcl --message body); _claim "$am_cl"
"$RC" reply "$am_cl" --amend --message x >/dev/null 2>&1; assert_rc "amend on .claimed refused (rc6)" "$?" "6"
am_dn=$("$RC" file --origin w --kind question --slug amenddn --message body); _claim "$am_dn"; "$RC" ack "$am_dn" >/dev/null
"$RC" reply "$am_dn" --amend --message x >/dev/null 2>&1; assert_rc "amend on .done refused (rc6)" "$?" "6"
am_fl=$("$RC" file --origin w --kind question --slug amendfl --message body); _claim "$am_fl"; "$RC" fail "$am_fl" --reason nope >/dev/null
"$RC" reply "$am_fl" --amend --message x >/dev/null 2>&1; assert_rc "amend on .failed refused (rc6)" "$?" "6"
# amend on a replied request: new body byte-exact via BOTH write + fetch paths.
amid=$("$RC" file --origin remote-hank --kind question --slug amendok --reply required --message "ORIGINAL-REQUEST-PAYLOAD")
_claim "$amid"
"$RC" reply "$amid" --worker w1 --message "first reply body" >/dev/null
printf 'AMENDED\twith tab\nregex \\d+ and \\\\ end\n{"k":"v\\n"}\n\n' > "$WORK/amend.src"
sha_amend=$(sha256sum < "$WORK/amend.src" | cut -d' ' -f1)
"$RC" reply "$amid" --amend --file "$WORK/amend.src" >/dev/null; assert_rc "amend on .replied → rc0" "$?" "0"
assert_file "amend stays .replied.md" "$REQ/$amid.replied.md"
al=$(grep -n '^## Reply$' "$REQ/$amid.replied.md" | tail -1 | cut -d: -f1)
tail -n +$((al + 2)) "$REQ/$amid.replied.md" > "$WORK/amend.out"
assert_eq "amend: on-disk body sha == new source (byte-exact)" "$(sha256sum < "$WORK/amend.out" | cut -d' ' -f1)" "$sha_amend"
"$RC" fetch "$amid" results --principal remote-hank > "$WORK/amend.fetch"
assert_eq "amend: fetch results sha == new source (re-materialized)" "$(sha256sum < "$WORK/amend.fetch" | cut -d' ' -f1)" "$sha_amend"
amended_body=$(cat "$REQ/$amid.replied.md")
grep -q 'first reply body' <<<"$amended_body" \
    && assert_rc "amend: old reply body replaced" 1 0 || assert_rc "amend: old reply body replaced" 0 0
assert_contains "amend: amended_at stamped"                 "$amended_body" "amended_at:"
assert_eq       "amend: exactly one reply: block (no dupe)"  "$(grep -c '^reply:$' "$REQ/$amid.replied.md")" "1"
assert_eq       "amend: exactly one ## Reply section"        "$(grep -c '^## Reply$' "$REQ/$amid.replied.md")" "1"
assert_contains "amend: ## Details request payload preserved" "$amended_body" "ORIGINAL-REQUEST-PAYLOAD"

# ── F1 crash-safety: intermediate-name transition + reaper recovery ─────
# A CONTENT transition claims a NON-AUTHORITATIVE intermediate (.replying/
# .failing), writes content there, then finalizes to the terminal name — so the
# terminal name is NEVER observable partial. The CHAN_TRANSITION_MIDGAP_HOOK
# (fires in the claim↔content-mv gap) and CHAN_TRANSITION_FINALIZE_HOOK (fires
# in the content-mv↔finalize gap) simulate a crash at each point by `exit`ing
# mid-transition, leaving an intermediate on disk. Recovery is the watcher
# reaper (_requests_claim): a COMPLETE aged .replying → .replied byte-exact, an
# incomplete one → .failed.
source "$_monitor_dir/watcher/_requests.sh"

echo "== 17a. crash AFTER claim (incomplete .replying): no false-terminal, recover → .failed =="
c1=$("$RC" file --origin remote-ivy --kind question --slug crash1 --reply required --message "orig one")
_claim "$c1"
CHAN_TRANSITION_MIDGAP_HOOK='exit 99' "$RC" reply "$c1" --message "REPLY ONE never finalized" >/dev/null 2>&1
assert_file "17a: crash-after-claim left the .replying intermediate"     "$REQ/$c1.replying.md"
[[ ! -e "$REQ/$c1.replied.md" ]]; assert_rc "17a: no .replied terminal exposed by the crash" "$?" "0"
"$RC" await "$c1" --timeout 0 --principal remote-ivy >/dev/null 2>&1
assert_rc "17a: await on the crashed intermediate → pending rc4 (NOT a false rc0)" "$?" "4"
s=$("$RC" fetch "$c1" status --principal remote-ivy)
assert_eq "17a: fetch status → claimed (pending), never a terminal word"  "$s" "claimed"
"$RC" fetch "$c1" results --principal remote-ivy >/dev/null 2>&1
assert_rc "17a: fetch results → rc3 not-ready (no status/results contradiction)" "$?" "3"
grep -q '^## Reply$' "$REQ/$c1.replying.md" \
    && assert_rc "17a: incomplete .replying carries no ## Reply" 1 0 || assert_rc "17a: incomplete .replying carries no ## Reply" 0 0
# Age it just past max-age (default 3d) but keep RETENTION huge so the same
# reaper pass recovers → .failed WITHOUT then GC'ing the fresh terminal.
touch -d '4 days ago' "$REQ/$c1.replying.md"
MONITOR_REQUESTS_RETENTION_SECONDS=999999999 _requests_claim
assert_file "17a: reaper recovered the incomplete transition → .failed"  "$REQ/$c1.failed.md"
[[ ! -e "$REQ/$c1.replying.md" ]]; assert_rc "17a: intermediate consumed by recovery" "$?" "0"

echo "== 17b. crash AFTER content mv (complete .replying): no false-terminal, recover → .replied byte-exact =="
printf 'FINALIZED BODY\twith tab\nregex \\d+ and \\\\ end\n' > "$WORK/crash2.src"
sha_c2=$(sha256sum < "$WORK/crash2.src" | cut -d' ' -f1)
c2=$("$RC" file --origin remote-ivy --kind question --slug crash2 --reply required --message "orig two")
_claim "$c2"
CHAN_TRANSITION_FINALIZE_HOOK='exit 99' "$RC" reply "$c2" --file "$WORK/crash2.src" >/dev/null 2>&1
assert_file "17b: crash-after-content left the .replying intermediate"   "$REQ/$c2.replying.md"
[[ ! -e "$REQ/$c2.replied.md" ]]; assert_rc "17b: no .replied terminal exposed yet" "$?" "0"
"$RC" await "$c2" --timeout 0 --principal remote-ivy >/dev/null 2>&1
assert_rc "17b: await on a complete-but-unfinalized intermediate → pending rc4" "$?" "4"
grep -q '^## Reply$' "$REQ/$c2.replying.md"; assert_rc "17b: complete .replying already carries ## Reply" "$?" "0"
touch -d '4 days ago' "$REQ/$c2.replying.md"
MONITOR_REQUESTS_RETENTION_SECONDS=999999999 _requests_claim
assert_file "17b: reaper finalized FORWARD to .replied (reply not lost)"  "$REQ/$c2.replied.md"
[[ ! -e "$REQ/$c2.replying.md" ]]; assert_rc "17b: intermediate consumed by recovery" "$?" "0"
rlc=$(grep -n '^## Reply$' "$REQ/$c2.replied.md" | tail -1 | cut -d: -f1)
tail -n +$((rlc + 2)) "$REQ/$c2.replied.md" > "$WORK/crash2.out"
assert_eq "17b: recovered body sha == source (byte-exact through crash + recovery)" \
    "$(sha256sum < "$WORK/crash2.out" | cut -d' ' -f1)" "$sha_c2"

echo "== 18. F2: amend anchors STRUCTURALLY (reply body with ## Reply / reply: lookalikes) =="
# A reply body that itself contains a bare '## Reply' line and a 'reply:'
# lookalike must not corrupt the amend. The old `grep|tail -1` anchor mis-picked
# the body lookalike; the structural anchor (first '## Reply' after the fence) is
# immune.
f2=$("$RC" file --origin remote-jane --kind question --slug amendanchor --reply required --message "orig req payload")
_claim "$f2"
printf '## Reply\nreply: not-frontmatter\nline three keep-out\n' > "$WORK/f2first.src"
"$RC" reply "$f2" --file "$WORK/f2first.src" >/dev/null
printf 'AMENDED body line\n## Reply\nreply: still-not-fm\ntail line\n' > "$WORK/f2amend.src"
sha_f2=$(sha256sum < "$WORK/f2amend.src" | cut -d' ' -f1)
"$RC" reply "$f2" --amend --file "$WORK/f2amend.src" >/dev/null; assert_rc "18: amend with lookalike body → rc0" "$?" "0"
# Byte-exact amend body (extract via the SAME structural anchor: first ## Reply
# after the fence; the body's lookalikes are part of the body and survive).
fl=$(awk 'NR==1&&$0=="---"{fm=1;next} fm==1&&$0=="---"{fm=2;next} fm==2&&$0=="## Reply"{print NR;exit}' "$REQ/$f2.replied.md")
tail -n +$((fl + 2)) "$REQ/$f2.replied.md" > "$WORK/f2.out"
assert_eq "18: amend body byte-exact (lookalikes intact, no leaked fragment)" \
    "$(sha256sum < "$WORK/f2.out" | cut -d' ' -f1)" "$sha_f2"
# The old FIRST reply's distinctive body line is fully gone (no leaked fragment).
grep -q 'line three keep-out' "$REQ/$f2.replied.md" \
    && assert_rc "18: old reply fragment fully replaced" 1 0 || assert_rc "18: old reply fragment fully replaced" 0 0
# Exactly one reply: block in the frontmatter (no duplicate injected).
assert_eq "18: exactly one reply: block after a lookalike amend" "$(grep -c '^reply:$' "$REQ/$f2.replied.md")" "1"
# ## Reply lines == one section header + one body lookalike = 2 (no THIRD leaked header).
assert_eq "18: header + one body lookalike, no duplicate header" "$(grep -c '^## Reply$' "$REQ/$f2.replied.md")" "2"

echo "== 19. ROUND-3 BLOCKER-1: request body quoting ## Reply, MIDGAP crash → reaper .failed (NOT false .replied) =="
# The reaper completeness check must key on FRONTMATTER (state: replied), never a
# forgeable ## Reply grep. Craft a request whose ## Details quotes both a bare
# '## Reply' line AND 'state: replied' (as body text). Crash BEFORE the content
# mv (MIDGAP) so .replying still holds the ORIGINAL request content (frontmatter
# state: new). The reaper MUST send it to .failed, not forward-finalize it.
printf 'here is a doc excerpt:\n## Reply\nstate: replied\nnot a genuine reply at all\n' > "$WORK/b1.src"
b1=$("$RC" file --origin remote-ken --kind question --slug b1exploit --reply required --file "$WORK/b1.src")
_claim "$b1"
CHAN_TRANSITION_MIDGAP_HOOK='exit 99' "$RC" reply "$b1" --message "REAL REPLY never landed" >/dev/null 2>&1
assert_file "19: MIDGAP crash left the .replying intermediate"          "$REQ/$b1.replying.md"
# Frontmatter state is the request's (new) despite the forgeable body text.
assert_eq   "19: crashed .replying FRONTMATTER state is not replied (unforgeable)" \
    "$(_chan_frontmatter_field "$REQ/$b1.replying.md" state)" "new"
touch -d '4 days ago' "$REQ/$b1.replying.md"
MONITOR_REQUESTS_RETENTION_SECONDS=999999999 _requests_claim
assert_file "19: reaper sent the forgeable-body intermediate to .failed"  "$REQ/$b1.failed.md"
[[ ! -e "$REQ/$b1.replied.md" ]]; assert_rc "19: NOT forward-finalized to .replied (no false-terminal)" "$?" "0"
"$RC" await "$b1" --timeout 0 --principal remote-ken >/dev/null 2>&1
assert_rc   "19: await on the reaped request → failed rc2 (never a false rc0)" "$?" "2"

echo "== 20. ROUND-3 BLOCKER-2: request ## Details quoting ## Reply — amend preserves the request byte-exact =="
# The amend split keys on the body_bytes marker (reply body = last N bytes), NOT
# a ## Reply search, so a '## Reply' line inside the REQUEST ## Details cannot
# make the strip delete the request tail (the demonstrated data-loss exploit).
printf 'REQUEST TOP LINE\n## Reply\nfake reply inside the request body\nREQUEST TAIL MUST SURVIVE\n' > "$WORK/b2req.src"
b2=$("$RC" file --origin remote-lee --kind question --slug b2exploit --reply required --file "$WORK/b2req.src")
_claim "$b2"
"$RC" reply "$b2" --message "genuine first reply body" >/dev/null
printf 'AMENDED REPLY BODY ONLY\n' > "$WORK/b2amend.src"
sha_b2=$(sha256sum < "$WORK/b2amend.src" | cut -d' ' -f1)
"$RC" reply "$b2" --amend --file "$WORK/b2amend.src" >/dev/null; assert_rc "20: amend with a request-body ## Reply lookalike → rc0" "$?" "0"
b2body=$(cat "$REQ/$b2.replied.md")
assert_contains "20: request ## Details TAIL survived the amend (no data loss)" "$b2body" "REQUEST TAIL MUST SURVIVE"
assert_contains "20: request ## Details TOP survived"                          "$b2body" "REQUEST TOP LINE"
assert_contains "20: new amend body present"                                   "$b2body" "AMENDED REPLY BODY ONLY"
grep -q 'genuine first reply body' <<<"$b2body" \
    && assert_rc "20: old reply body replaced" 1 0 || assert_rc "20: old reply body replaced" 0 0
# byte-exact new reply body via the client-facing fetch results path (which
# itself keys on the unforgeable body_bytes boundary).
"$RC" fetch "$b2" results --principal remote-lee > "$WORK/b2.out"
assert_eq "20: amend body byte-exact via fetch results (body_bytes-keyed)" "$(sha256sum < "$WORK/b2.out" | cut -d' ' -f1)" "$sha_b2"

echo "== 20b. amend REFUSES a legacy reply lacking a body_bytes marker (no guessing) =="
lg=$("$RC" file --origin remote-lee --kind question --slug legacyamend --reply required --message "orig legacy")
_claim "$lg"
"$RC" reply "$lg" --message "legacy-style reply body" >/dev/null
# simulate a pre-marker legacy reply by stripping the body_bytes line
grep -v '^  body_bytes:' "$REQ/$lg.replied.md" > "$REQ/$lg.replied.md.t" && mv "$REQ/$lg.replied.md.t" "$REQ/$lg.replied.md"
"$RC" reply "$lg" --amend --message "should be refused" >/dev/null 2>&1
assert_rc       "20b: amend on a legacy reply (no body_bytes) → refuse rc6" "$?" "6"
assert_contains "20b: legacy reply left intact after the refusal" "$(cat "$REQ/$lg.replied.md")" "legacy-style reply body"

echo "== 20c. legacy fetch-results REFUSES an ambiguous ## Reply (no body_bytes, no results.md) =="
lg2=$("$RC" file --origin remote-lee --kind question --slug legacyfetch --reply required --message "orig2")
_claim "$lg2"
printf 'line A\n## Reply\nline B\n' > "$WORK/lg2.src"      # body carries a 2nd ## Reply
"$RC" reply "$lg2" --file "$WORK/lg2.src" >/dev/null
grep -v '^  body_bytes:' "$REQ/$lg2.replied.md" > "$REQ/$lg2.replied.md.t" && mv "$REQ/$lg2.replied.md.t" "$REQ/$lg2.replied.md"
rm -f "$REQ/replies/$lg2/results.md"                       # force the reconstruct fallback
"$RC" fetch "$lg2" results --principal remote-lee >/dev/null 2>&1
assert_rc "20c: legacy ambiguous ## Reply fetch-results refuses (rc2), never guesses" "$?" "2"

echo "== 21. list surfaces replying/failing intermediates (G2) =="
# A crashed content transition parks the request at a .replying/.failing
# intermediate for up to MONITOR_REQUESTS_INTERMEDIATE_MAX_AGE_SECONDS before
# the reaper recovers it. Pre-fix, `list --state all` globbed only the five
# stable states, so the id appeared NOWHERE in the listing while
# `fetch status` reported it as claimed — invisible to the operator debugging
# a stuck reply. Stage each intermediate by rename (exactly what a crash
# leaves behind; same staging as _claim).
li1=$("$RC" file --origin remote-mia --kind question --slug listreplying --reply required --message "stuck reply")
_claim "$li1"
mv "$REQ/$li1.claimed.md" "$REQ/$li1.replying.md"
li2=$("$RC" file --origin remote-mia --kind question --slug listfailing --reply required --message "stuck fail")
_claim "$li2"
mv "$REQ/$li2.claimed.md" "$REQ/$li2.failing.md"
lall=$("$RC" list --state all)
assert_contains "21: list --state all shows the .replying intermediate"   "$lall" "[replying] $li1.replying"
assert_contains "21: list --state all shows the .failing intermediate"    "$lall" "[failing ] $li2.failing"
# Selected under --state claimed: readers treat intermediates like claimed
# (the same rule fetch status applies) — the enum stays the five stable words.
lcl=$("$RC" list --state claimed)
assert_contains "21: list --state claimed includes the .replying intermediate" "$lcl" "$li1.replying"
assert_contains "21: list --state claimed includes the .failing intermediate"  "$lcl" "$li2.failing"
# Excluded from every OTHER stable-state selector (not terminal, not new).
for _st in new replied done failed; do
    lst=$("$RC" list --state "$_st")
    grep -qF -- "$li1" <<<"$lst" || grep -qF -- "$li2" <<<"$lst" \
        && assert_rc "21: intermediates absent from --state $_st" 1 0 \
        || assert_rc "21: intermediates absent from --state $_st" 0 0
done
# The enum is UNCHANGED: the literal intermediate words are not selectors.
"$RC" list --state replying >/dev/null 2>&1
assert_rc "21: --state replying refused (enum unchanged) → rc1" "$?" "1"
"$RC" list --state failing >/dev/null 2>&1
assert_rc "21: --state failing refused (enum unchanged) → rc1" "$?" "1"
# fetch status's claimed-mapping is untouched: list shows the literal word,
# status still reports the pending family as `claimed` (no false terminal).
lst1=$("$RC" fetch "$li1" status --principal remote-mia)
assert_eq "21: fetch status on .replying still reports claimed" "$lst1" "claimed"
lst2=$("$RC" fetch "$li2" status --principal remote-mia)
assert_eq "21: fetch status on .failing still reports claimed"  "$lst2" "claimed"

echo
if (( FAIL == 0 )); then echo "ALL TESTS PASSED ($PASS)"; exit 0
else echo "SOME TESTS FAILED ($FAIL failed, $PASS passed)" >&2; exit 1; fi
