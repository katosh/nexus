#!/usr/bin/env bash
# A DELIVERED VERDICT MUST REACH THE LEDGER, AND AN ARM MUST BE ABLE TO NAME ITS
# SUBJECT (your-org/nexus-code#1207, #1191, #1199, #1190).
#
# Run: bash monitor/watcher/test-skeptic-arm-recording.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# ── THE DEFECT ──────────────────────────────────────────────────────────────
#
# The skeptic protocol's armed state had TWO writers and only one of them could
# name a subject:
#
#   monitor/ng (wrap-up --skeptic-decision require)  marker + `armed` ledger row
#   monitor/spawn-worker.sh (--skeptic-role)         marker ONLY
#
# spawn-worker's own comment states its position: for a first-pass skeptic its
# write is an idempotent re-stamp, but "for a SECOND-or-later pass it is the ONLY
# thing that restores the block". So every re-validation round armed with no
# subject — and those are the rounds that exist BECAUSE something was already
# found wrong.
#
# `_skeptic_record_discharge` then closed the loop the wrong way. With no arm on
# record it set detail `no-arm-on-record` and `return 0`d WRITING NOTHING, on the
# reasoning that such a row "answers no question". It answers the only question
# `_skeptic_verdict_evidence` exists for. Dropping it makes the key report
# `evidence=none` — which that reader's own header calls "a POSITIVE claim
# ('nothing has ever settled this key')" — and `none`'s documented instruction is
# *nobody reviewed the work, get a review*. So a reviewer's completed pass became
# an instruction to duplicate it, at rc 0.
#
# MEASURED ON THE LIVE BOARD, 2026-08-31, `.state/skeptic/pending`:
#   · `.ncpanestate.ledger`: ONE `armed` row against FOUR rounds of review, so
#     all SIX delivered verdicts read `asserted-not-armed` — the arm never moved
#     while the report was amended under it.
#   · `annz36` logged `subject-armed-sha:"-"` at verdict time with NO
#     `skeptic-request` event at all: armed by spawn-worker, never by a wrap-up.
#   · 19 of 64 ledgers print `matched=0 superseded=0`, and 14 of those carry a
#     non-empty `standing_verdict` — a delivered verdict the supersession
#     machinery cannot rank, reported as though ranked and found fine.
#
# ── WHAT THIS SUITE PINS, AND WHY EACH ARM CAN FAIL ─────────────────────────
#
# Every assertion below was SEEN TO FAIL against the pre-fix tree (the ledger
# helpers are driven directly, so the mutation is a one-line revert), and the
# suite pins its own assertion COUNT: an `assert_*` inside `( )` mutates a
# subshell's globals and cannot fail the suite, and a MISSING helper is rc 127
# counted by nothing, so a green verdict alone is not evidence the arms ran.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
NG="$REPO_ROOT/monitor/ng"
SPAWN="$REPO_ROOT/monitor/spawn-worker.sh"
OBLIG="$REPO_ROOT/monitor/obligations.sh"

[[ -x "$NG" ]]      || th_abort "monitor/ng not executable at $NG"
[[ -r "$SPAWN" ]]   || th_abort "monitor/spawn-worker.sh not readable at $SPAWN"
[[ -r "$OBLIG" ]]   || th_abort "monitor/obligations.sh not readable at $OBLIG"

WORK=$(mktemp -d -t nexus-skarm-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/.state"
PEND="$STATE/skeptic/pending"
mkdir -p "$PEND" "$WORK/reports"

# ESTABLISH THIS SUITE'S STATE DIRECTORY, AND FAIL CLOSED IF THE PIN DOES NOT
# TAKE (your-org/nexus-code#1306). Every `--state-dir` below pins the LEDGER
# and nothing else: `ng` resolves its process-level `STATE_DIR` at startup from
# the INHERITED `$NEXUS_ROOT`, and its usage tap fires before dispatch — so in
# an agent shell this suite appended to the operator's canonical
# `monitor/.state/`, at rc 0, with every assertion green. Exported rather than
# passed per call, because the leak is a property of every `ng` this file
# starts including ones a future case adds. See th_pin_ng_state for the
# measurement and for what the check does NOT cover.
th_pin_ng_state "$NG" "$STATE"

_ev() { "$NG" skeptic-evidence "$1" --state-dir "$STATE" 2>/dev/null | sed -n 1p; }
_field() { sed -n "s/.*[[:space:]]$2=\([^[:space:]][^[:space:]]*\).*/\1/p" <<<"$1"; }

# ═══ 1. THE RECORDING PATH: a verdict against an arm-less key ═══════════════
#
# Driven through the real private helpers rather than a hand-written row, so
# what is pinned is the WRITER's behaviour and not a fixture's shape.
_drive() {   # _drive <key> <verdict> <issue> <by> [asserted-sha]
    { sed -n '/^_skeptic_ledger_file()/,/^}/p'        "$NG"
      sed -n '/^_skeptic_artefact_sha()/,/^}/p'       "$NG"
      sed -n '/^_skeptic_record_arm()/,/^}/p'         "$NG"
      sed -n '/^_skeptic_open_arms()/,/^}/p'          "$NG"
      # your-org/nexus-code#1252. `_skeptic_record_discharge` CALLS this to
      # narrow an ambiguity by issue. Omit it and the driver silently measures
      # the FALLBACK path — an undefined command, `_sk_narrow=""`, ambiguous —
      # which is indistinguishable from the defect the guard is testing for,
      # and which makes every negative control below pass VACUOUSLY.
      sed -n '/^_skeptic_open_arms_for_issue()/,/^}/p' "$NG"
      sed -n '/^_skeptic_record_discharge()/,/^}/p'   "$NG"
      printf '_skeptic_record_discharge %q %q %q %q %q %q\n' \
          "$PEND" "$1" "$2" "$3" "$4" "${5:-}"
    } | bash
}

# POSITIVE CONTROL FIRST. If the driver cannot write a row at all, every absence
# below is a false zero — this is the check `#1150` was caught by not running.
SHA_OK=$(printf 'armed body\n' | sha256sum | awk '{print $1}')
printf 'armed body\n' > "$WORK/reports/ctl.md"
"$NG" skeptic-arm ctl --report "$WORK/reports/ctl.md" --issue 1207 \
    --state-dir "$STATE" >/dev/null 2>&1
_drive ctl credible 1207 sk-ctl ""
# `|| true`, NOT `|| echo 0`: `grep -c` exits 1 on a count of zero, having
# ALREADY printed its own `0`, so `|| echo 0` emits TWO zeroes and the comparison
# fails on a value that is arithmetically correct. All three sites here expect
# "1", so this was a confusing message rather than a false PASS — but the same
# construct guarding an expected "0" would fail a correct answer.
assert_eq "POSITIVE CONTROL: the driver CAN write a discharge row" \
    "$(grep -c '^discharged' "$PEND/.ctl.ledger" 2>/dev/null || true)" "1"
assert_contains "POSITIVE CONTROL: and it attributes cleanly" \
    "$(cat "$PEND/.ctl.ledger")" "attributed"

# THE DEFECT ARM. No arm on record, no --skeptic-subject. Pre-fix this wrote
# NOTHING and the file did not exist.
_drive noarm credible 1208 sk-x ""
assert_eq "a verdict against an ARM-LESS key is RECORDED, not dropped" \
    "$( [[ -e "$PEND/.noarm.ledger" ]] && echo present || echo ABSENT)" "present"
assert_contains "…carrying detail no-arm-on-record" \
    "$(cat "$PEND/.noarm.ledger" 2>/dev/null)" "no-arm-on-record"
assert_contains "…and the verdict itself, which is the irreplaceable fact" \
    "$(cat "$PEND/.noarm.ledger" 2>/dev/null)" "credible"
# The subject field must be `-`: a recorded row must not become a suppression
# licence. `_skeptic_artefact_discharged` requires a 64-hex match, so `-` is
# inert there by construction — pinned because a future edit that put a sha here
# would silently start authorising skipped validation (#1067).
assert_eq "…with subject \`-\`, so it can authorise no suppression" \
    "$(awk -F'\t' '$1=="discharged"{print $2}' "$PEND/.noarm.ledger" 2>/dev/null)" "-"

# THE TWO SHAPES MUST STAY DISTINCT. A ledger that EXISTS with nothing
# outstanding is `no-open-arm` — the ordinary terminal verdict of a chain whose
# last round closed cleanly, and NOT a bookkeeping failure. A key with NO ledger
# at all is `verdict-without-arm`: nothing ever armed it with a subject. Same
# `n == 0` branch, different causes, different remedies; folding them together
# would hand the operator one instruction for two situations.
# A DIFFERENT reviewer: the same (verdict, issue, by) tuple re-delivered with
# nothing armed in between is the re-run `#1370` now refuses to re-record (see
# section 6), so the second verdict here is a genuine second party.
_drive ctl credible 1207 sk-ctl2 ""
assert_eq "a SECOND verdict on a ledger with nothing open is no-open-arm" \
    "$(awk -F'\t' '$1=="discharged"{d=$7} END{print d}' "$PEND/.ctl.ledger")" "no-open-arm"
assert_eq "…and it is NOT confused with the no-ledger shape" \
    "$(_field "$(_ev ctl)" evidence)" "no-open-arm"

# ═══ 2. WHAT THE OPERATOR IS TOLD — the whole point of recording it ═════════
_ev_noarm=$(_ev noarm)
assert_eq "the class is verdict-without-arm, NOT none" \
    "$(_field "$_ev_noarm" evidence)" "verdict-without-arm"
assert_eq "…and the verdict is COUNTED" \
    "$(_field "$_ev_noarm" verdicts)" "1"
assert_eq "…and it is the STANDING verdict" \
    "$(_field "$_ev_noarm" standing_verdict)" "credible"
# `verdict-without-arm` must be more specific than the catch-all it sits above:
# `unmatched-other` means "a detail this reader does not KNOW", and reporting a
# known detail as unrecognised is a false statement in the other direction.
assert_eq "…and NOT the unmatched-other catch-all" \
    "$( [[ "$(_field "$_ev_noarm" evidence)" == "unmatched-other" ]] && echo yes || echo no)" "no"

# THE ASYMMETRY THAT MADE THIS DANGEROUS. `--skeptic-subject` is OPTIONAL, and
# pre-fix it was the ONLY thing standing between a recorded verdict and an erased
# one. Two keys, identical histories, that flag the only variable: they must now
# agree that a verdict EXISTS. They still differ in class, which is correct —
# asserting a subject is more information, not less.
_drive withsubj credible 1208 sk-x "$SHA_OK"
_ev_with=$(_ev withsubj)
assert_eq "the flag is no longer what decides whether a verdict SURVIVES" \
    "$(_field "$_ev_with" verdicts)" "$(_field "$_ev_noarm" verdicts)"
assert_eq "…and asserting a subject still says MORE (unmatched-subject)" \
    "$(_field "$_ev_with" evidence)" "unmatched-subject"

# ═══ 2b. THE ROW RECORDS DELIVERY, NEVER ATTRIBUTION — AND CANNOT BE PROMOTED ═
#
# The condition attached to the ruling that this row be recorded at all. The
# steelman for DROPPING it is that a row with no subject might later be matched
# to something the review was not about, and a FALSE ATTRIBUTION is worse than a
# missing one. So the row must be permanently unpromotable: if a subject is
# established afterwards, that has to be a fresh arm and a fresh verdict, never a
# retroactive re-reading of this row.
#
# ASSERTED BY ATTEMPTING THE PROMOTION AND SHOWING IT REFUSED, not by asserting
# that no promoting code path exists. An absence-of-code-path assertion is a
# claim about the tree you searched — this workspace's dominant defect class —
# and it silently stops holding the day someone adds the path. Attempting the act
# tests the property.
#
# The promotion is attempted in the strongest form available: arm the very sha a
# reader might want to match this verdict to, AFTER the row is on the ledger.
_promo_sha=$(printf 'the artefact a reader might want to credit' | sha256sum | awk '{print $1}')
printf 'promo\n' > "$WORK/reports/promo.md"

# The `verdict-without-arm` row is already on `.noarm.ledger` from section 1.
assert_eq "PRECONDITION: the row is present and names no artefact" \
    "$(awk -F'\t' '$1=="discharged"{print $2}' "$PEND/.noarm.ledger")" "-"

# (a) BEFORE any arm — the row must answer for no artefact at all.
_sk_disch_probe() {   # rc of _skeptic_artefact_discharged, via the real helper
    { sed -n '/^_skeptic_ledger_file()/,/^}/p'          "$NG"
      sed -n '/^_skeptic_artefact_discharged()/,/^}/p'  "$NG"
      printf '_skeptic_artefact_discharged %q %q %q >/dev/null 2>&1; echo $?\n' "$PEND" "$1" "$2"
    } | bash
}
assert_eq "the row discharges NO artefact before any arm exists" \
    "$(_sk_disch_probe noarm "$_promo_sha")" "1"

# (b) NOW ESTABLISH THE SUBJECT AFTER THE FACT — the promotion attempt.
"$NG" skeptic-arm noarm --report "$WORK/reports/promo.md" --issue 1208 \
    --state-dir "$STATE" >/dev/null 2>&1
_armed_sha=$(awk -F'\t' '$1=="armed"{s=$2} END{print s}' "$PEND/.noarm.ledger")
assert_eq "POSITIVE CONTROL: the later arm really was recorded" \
    "$( [[ "$_armed_sha" =~ ^[0-9a-f]{64}$ ]] && echo yes || echo no)" "yes"

# (c) THE REFUSALS. The pre-existing `-` row must not answer for it, must not
#     close it, and must not make the key read as attributed.
assert_eq "…and the earlier row STILL discharges nothing (promotion refused)" \
    "$(_sk_disch_probe noarm "$_armed_sha")" "1"
assert_contains "…the newly-armed artefact is still OUTSTANDING, not closed by it" \
    "$( { sed -n '/^_skeptic_ledger_file()/,/^}/p' "$NG"
          sed -n '/^_skeptic_open_arms()/,/^}/p'   "$NG"
          printf '_skeptic_open_arms %q %q\n' "$PEND" noarm; } | bash )" "$_armed_sha"
_ev_promo=$(_ev noarm)
assert_eq "…the key does NOT read attributed" \
    "$( [[ "$(_field "$_ev_promo" evidence)" == "attributed" ]] && echo yes || echo no)" "no"
assert_eq "…and matched is still 0: delivery was recorded, attribution was not" \
    "$(_field "$_ev_promo" matched)" "0"

# (c2) THE OTHER TEMPORAL DIRECTION — a subject-less row landing AFTER arms must
#      close none of them. Written because a mutation exposed the gap: removing
#      the 64-hex guard on `delete seen[$2]` left this suite GREEN, since every
#      subject-less row in the fixture above happens to precede its arm, so file
#      order alone kept the arm outstanding. A guard that holds only because of
#      the order the fixture was built in is not tested.
#
#      The shape is real: with TWO arms outstanding a verdict records
#      `ambiguous-2-arms-outstanding` with subject `-`, and if that `-` could
#      close an arm it would silently retire one of two obligations nobody
#      reviewed.
#
#      AND THE MUTATION CORRECTED WHAT PROTECTS IT. Removing the 64-hex guard on
#      `delete seen[$2]` at BOTH sites left this block green, because `seen[]` is
#      only ever keyed by an armed 64-hex subject, so `delete seen["-"]` is a
#      no-op regardless. That guard is defence in depth, not the mechanism —
#      worth recording, because a comment claiming it is load-bearing would send
#      the next reader to defend the wrong line. What DOES break the property is
#      a writer that silently upgrades an unattributable verdict: mutating the
#      ambiguous branch to take the first open arm and call it `attributed`
#      reddens both assertions below. That is the promotion this must refuse.
printf 'two-a\n' > "$WORK/reports/two-a.md"
printf 'two-b\n' > "$WORK/reports/two-b.md"
"$NG" skeptic-arm ambig --report "$WORK/reports/two-a.md" --state-dir "$STATE" >/dev/null 2>&1
"$NG" skeptic-arm ambig --report "$WORK/reports/two-b.md" --state-dir "$STATE" >/dev/null 2>&1
_ambig_open_before=$( { sed -n '/^_skeptic_ledger_file()/,/^}/p' "$NG"
                        sed -n '/^_skeptic_open_arms()/,/^}/p'   "$NG"
                        printf '_skeptic_open_arms %q %q\n' "$PEND" ambig; } | bash | grep -c . )
assert_eq "POSITIVE CONTROL: two distinct artefacts are outstanding" \
    "$_ambig_open_before" "2"
_drive ambig check 1208 sk-ambig ""
assert_contains "…so the verdict records ambiguity, with subject \`-\`" \
    "$(tail -1 "$PEND/.ambig.ledger")" "ambiguous-2-arms-outstanding"
_ambig_open_after=$( { sed -n '/^_skeptic_ledger_file()/,/^}/p' "$NG"
                       sed -n '/^_skeptic_open_arms()/,/^}/p'   "$NG"
                       printf '_skeptic_open_arms %q %q\n' "$PEND" ambig; } | bash | grep -c . )
assert_eq "…and that subject-less row CLOSES NEITHER arm" \
    "$_ambig_open_after" "2"

# (d) THE SANCTIONED ROUTE STILL WORKS — otherwise this would be a cage, not a
#     rule. A FRESH verdict against the FRESH arm attributes cleanly.
_drive noarm credible 1208 sk-fresh ""
assert_eq "a FRESH verdict against the FRESH arm DOES attribute" \
    "$(awk -F'\t' '$1=="discharged"{d=$7} END{print d}' "$PEND/.noarm.ledger")" "attributed"

# ═══ 3. `superseded=0` MUST NOT READ AS REASSURANCE WITH NO ATTRIBUTED ROW ══
#
# `sup_state` is computed only inside `matchedline > 0`, so an all-unmatched
# ledger cannot reach `1` or `?` and falls through at the initialiser to `0` —
# whose documented gloss is "nothing; the attributed row is fine". There is no
# attributed row. The VALUE stays `0` (it is read by retire-preflight and
# skeptic-channel, and only `1` licenses discarding a verdict), so the honesty
# goes on `superseded_why`, the field that exists to make the judgement
# checkable.
assert_eq "superseded_why NAMES the absence of an attributed row" \
    "$(_field "$_ev_noarm" superseded_why)" "no-attributed-row-to-supersede"
assert_eq "…the VALUE stays 0, so no gate's behaviour is changed by the wording" \
    "$(_field "$_ev_noarm" superseded)" "0"
assert_eq "…and attributed_verdict is indeed empty, which is what makes 0 vacuous" \
    "$(_field "$_ev_noarm" attributed_verdict)" "-"
# NON-VACUITY: the new `why` must NOT appear on a ledger that HAS an attributed
# row, or it would be a constant rather than a finding — the `detail`-never-varies
# shape this bundle came from. `ctl` has `matched>=1`, so the vacuity condition
# (`matched == 0`) is false there and some OTHER `superseded_why` may legitimately
# apply; what must never happen is this one.
assert_eq "the new why does NOT fire where an attributed row EXISTS" \
    "$( [[ "$(_field "$(_ev ctl)" superseded_why)" == "no-attributed-row-to-supersede" ]] && echo fired || echo quiet)" "quiet"
assert_eq "…and ctl really does have an attributed row (control for the above)" \
    "$( (( $(_field "$(_ev ctl)" matched) >= 1 )) && echo yes || echo no)" "yes"

# ═══ 4. `ng skeptic-arm` — the verb that lets an outside writer name a subject ═
printf 'v1\n' > "$WORK/reports/r1.md"
_out=$("$NG" skeptic-arm t1 --report "$WORK/reports/r1.md" --issue 1207 --state-dir "$STATE" 2>&1)
assert_eq "skeptic-arm records an arm (rc 0)" "$?" "0"
assert_contains "…and says what it armed" "$_out" "armed t1 sha="
assert_eq "…and the ledger holds exactly one armed row" \
    "$(grep -c '^armed' "$PEND/.t1.ledger" 2>/dev/null || true)" "1"

# IDEMPOTENCE IS LOAD-BEARING. spawn-worker's marker write is deliberately an
# idempotent re-stamp and runs on FIRST-pass spawns where the worker's `require`
# wrap-up already armed these exact bytes. Appending again would put TWO open
# arms on one artefact, which IS `ambiguous-N-arms-outstanding` — pole B of
# #1156. A fix for pole A that manufactures pole B is not a fix.
"$NG" skeptic-arm t1 --report "$WORK/reports/r1.md" --issue 1207 --state-dir "$STATE" >/dev/null 2>&1
assert_eq "a re-stamp of an OUTSTANDING artefact appends nothing (rc 3)" "$?" "3"
assert_eq "…so the ledger still holds exactly ONE armed row" \
    "$(grep -c '^armed' "$PEND/.t1.ledger" 2>/dev/null || true)" "1"
assert_eq "…and the key does not become ambiguous-arms" \
    "$( [[ "$(_field "$(_ev t1)" evidence)" == ambiguous-arms ]] && echo yes || echo no)" "no"

# A DISCHARGED artefact re-arms: that is a genuine new round on unchanged bytes,
# and refusing it would be the opposite error (a round with no arm).
_drive t1 check 1207 sk-t1 ""
"$NG" skeptic-arm t1 --report "$WORK/reports/r1.md" --issue 1207 --state-dir "$STATE" >/dev/null 2>&1
_rc_rearm=$?
assert_eq "a DISCHARGED artefact re-arms for a new round (rc 0)" "$_rc_rearm" "0"

# COULD NOT NAME A SUBJECT is exit 4 and is LOUD. Silence here is the whole
# defect: an unreadable report used to leave a shut gate and an empty ledger with
# nothing said. Measured failure modes of `_skeptic_artefact_sha`: a relative
# path resolved from the wrong cwd, a missing file, an unreadable file, a
# directory, an empty argument — all rc 1, all silent at the call site.
_out4=$("$NG" skeptic-arm t2 --report "$WORK/reports/absent.md" --state-dir "$STATE" 2>&1)
assert_eq "an unnameable subject is exit 4, not a silent skip" "$?" "4"
assert_contains "…and it SAYS so" "$_out4" "COULD NOT NAME A SUBJECT"
assert_contains "…naming the resolution it attempted" "$_out4" "resolved to"
assert_eq "…and writes no ledger" \
    "$( [[ -e "$PEND/.t2.ledger" ]] && echo present || echo absent)" "absent"

# NEXUS_ROOT-RELATIVE RESOLUTION. `ng report-init` pins reports to the PRIMARY
# corpus, so a worker in a secondary clone hands over a path that is unreadable
# from its own cwd. Without this two-step the arm silently carried no subject —
# the dominant real-world route into the defect.
mkdir -p "$WORK/root/reports"
printf 'in the corpus\n' > "$WORK/root/reports/rel.md"
( cd "$WORK" && NEXUS_ROOT="$WORK/root" "$NG" skeptic-arm t3 \
    --report reports/rel.md --state-dir "$STATE" >/dev/null 2>&1 )
assert_eq "a NEXUS_ROOT-relative report resolves and arms (rc 0)" "$?" "0"
assert_contains "…and the row records the RESOLVED path" \
    "$(cat "$PEND/.t3.ledger" 2>/dev/null)" "$WORK/root/reports/rel.md"

# ═══ 5. A FULL spawn-worker.sh RUN MUST RECORD THE ARM ══════════════════════
#
# ── WHY THIS IS NOT A TEXT CHECK, AND NO LONGER A PARTIAL ONE ─────────────
#
# The first version asserted that the marker block CONTAINS
# `monitor/ng" skeptic-arm`. That is a check on a PROXY — the text is present —
# standing in for the PROPERTY — an arm is recorded. It passed GREEN over a fix
# that recorded nothing in 98.9% of real spawns:
#
#     for _sk_arm_win in "$SKEPTIC_TARGET" "$SKEPTIC_ORIG"; do
#         [ -n "$_sk_arm_win" ] || continue
#         [ "$_sk_arm_win" = "$SKEPTIC_ORIG" ] \
#             && [ "$SKEPTIC_ORIG" = "$SKEPTIC_TARGET" ] && continue
#
# whose dedup guard was meant to skip the SECOND iteration when ORIG == TARGET
# and skipped BOTH — on iteration 1 the window IS the target, so both tests hold.
# ORIG == TARGET is the DEFAULT (`SKEPTIC_ORIG="$SKEPTIC_TARGET"` whenever
# `--skeptic-orig` is omitted, which a first-pass spawn deliberately does):
# measured 818 spawns against 9 over `action-log.jsonl`, 83 against 1 since the
# ledger feature landed. It also failed SILENTLY — `-r` was supplied, so the
# no-report warning could not fire.
#
# The second version executed the marker/arm BLOCK, which caught the bug but was
# a partial: it could not show the block is REACHED. That limit is now closed.
# This runs the REAL `spawn-worker.sh`, top to bottom, with a tmux STUB on PATH
# (the `test-spawn-worker.sh` pattern — `info) exit 0` is what gets past the
# "no current client" refusal that blocks a detached fixture server) and the REAL
# `ng` symlinked in, so a real ledger row is written by the real writer.
#
# The DEFAULT shape is the primary case and the recursive one is the control,
# deliberately: the recursive path was the ONLY branch the broken loop handled,
# so a suite driving only it cannot see the defect.

_SW_FIX=$(mktemp -d -t nexus-swfix-XXXXXX)
_sw_cleanup() { rm -rf "$_SW_FIX"; }
trap '_sw_cleanup; rm -rf "$WORK"' EXIT

# One fake nexus per case, so a leaked row from one cannot answer for another.
_mk_nexus() {   # _mk_nexus <dir>
    local fn="$1"
    mkdir -p "$fn/monitor" "$fn/skills/nexus.worker-defaults" "$fn/reports" \
             "$fn/node_modules/.bin" "$fn/monitor/.state/windows"
    cp "$SPAWN" "$fn/monitor/spawn-worker.sh"; chmod +x "$fn/monitor/spawn-worker.sh"
    cp "$REPO_ROOT/monitor/guard-block.sh.in" "$fn/monitor/"
    local d
    for d in _claude-bin.sh _tmux-window.sh _fm_lib.sh _channel_lib.sh _bookkeeping.sh; do
        cp "$REPO_ROOT/monitor/$d" "$fn/monitor/"
    done
    cp "$REPO_ROOT/monitor/request-channel.sh" "$fn/monitor/"
    chmod +x "$fn/monitor/request-channel.sh"
    cp "$REPO_ROOT/skills/nexus.worker-defaults/SKILL.md" "$fn/skills/nexus.worker-defaults/"
    # The REAL ng. `ng` resolves its own deps through `readlink -f "$BASH_SOURCE"`,
    # so a symlink gives the real script with its real libraries while
    # `--state-dir` keeps every write inside this fixture. A STUBBED ng would
    # defeat the whole point: the row has to be written by the real writer.
    ln -s "$REPO_ROOT/monitor/ng" "$fn/monitor/ng"
    printf '#!/bin/bash\nexit 0\n' > "$fn/node_modules/.bin/claude"
    chmod +x "$fn/node_modules/.bin/claude"
    printf '{}\n' > "$fn/monitor/worker-settings.json"
    printf '# the artefact under review\n' > "$fn/reports/victim.md"
    printf '{"window":"victimwin","session_id":"11111111-2222-3333-4444-555555555555","kind":"task"}\n' \
        > "$fn/monitor/.state/windows/victimwin.json"
    printf '{"window":"rootwin","session_id":"66666666-7777-8888-9999-aaaaaaaaaaaa","kind":"task"}\n' \
        > "$fn/monitor/.state/windows/rootwin.json"
}
_STUB_BIN="$_SW_FIX/stub-bin"; mkdir -p "$_STUB_BIN"
cat > "$_STUB_BIN/tmux" <<'STUB'
#!/bin/bash
case "$1" in
  info)         exit 0 ;;   # the "no current client" refusal is what this defeats
  list-windows) exit 0 ;;   # no windows -> the collision check passes
  new-window)   echo '@7'; exit 0 ;;
  *)            exit 0 ;;
esac
STUB
chmod +x "$_STUB_BIN/tmux"

_run_spawn() {   # _run_spawn <fake-nexus> <args...>
    local fn="$1"; shift
    PATH="$_STUB_BIN:$PATH" env -u TMUX -u CLAUDE_SESSION_ID -u NEXUS_WORKER_WINDOW \
        TMPDIR="$_SW_FIX/tmp" NEXUS_ROOT="$fn" NEXUS_STATE_DIR="$fn/monitor/.state" \
        "$fn/monitor/spawn-worker.sh" "$@" 2>&1
}
mkdir -p "$_SW_FIX/tmp"
_arms_on() { awk -F'\t' '$1=="armed"{print $2}' "$1/monitor/.state/skeptic/pending/.$2.ledger" 2>/dev/null; }

# ── 5a. THE DEFAULT SHAPE: --skeptic-orig OMITTED, so ORIG == TARGET ───────
_FN1="$_SW_FIX/n1"; _mk_nexus "$_FN1"
_sw_out1=$(_run_spawn "$_FN1" -n victim-sk -c "$_SW_FIX" -p "$WORK/reports/promo.md" \
    -r "$_FN1/reports/victim.md" --skeptic-role --skeptic-target victimwin)
assert_contains "POSITIVE CONTROL: the full spawn ran to completion" \
    "$_sw_out1" "spawned: window=victim-sk"
assert_eq "DEFAULT SPAWN: the marker is written for the target" \
    "$( [[ -e "$_FN1/monitor/.state/skeptic/pending/victimwin" ]] && echo yes || echo no)" "yes"
assert_eq "DEFAULT SPAWN: an ARM IS RECORDED for the target" \
    "$(_arms_on "$_FN1" victimwin | grep -c .)" "1"
assert_eq "DEFAULT SPAWN: …naming the report the reviewer was pointed at" \
    "$(_arms_on "$_FN1" victimwin)" \
    "$(sha256sum < "$_FN1/reports/victim.md" | awk '{print $1}')"
# Exactly one, in both directions: a duplicate arm for one artefact IS
# `ambiguous-N-arms-outstanding`, so over-arming is its own defect.
assert_eq "DEFAULT SPAWN: exactly ONE arm — no duplicate for the coinciding orig" \
    "$(_arms_on "$_FN1" victimwin | grep -c .)" "1"

# ── 5b. THE RECURSIVE SHAPE: a DISTINCT chain root (the control) ───────────
_FN2="$_SW_FIX/n2"; _mk_nexus "$_FN2"
_sw_out2=$(_run_spawn "$_FN2" -n victim-sk2 -c "$_SW_FIX" -p "$WORK/reports/promo.md" \
    -r "$_FN2/reports/victim.md" --skeptic-role --skeptic-target victimwin --skeptic-orig rootwin)
assert_contains "POSITIVE CONTROL: the recursive spawn ran to completion" \
    "$_sw_out2" "spawned: window=victim-sk2"
assert_eq "RECURSIVE SPAWN: an arm is recorded for the TARGET" \
    "$(_arms_on "$_FN2" victimwin | grep -c .)" "1"
assert_eq "RECURSIVE SPAWN: and one for the distinct ORIG (chain root)" \
    "$(_arms_on "$_FN2" rootwin | grep -c .)" "1"

# ── 5c. NO -r: loud, and no arm ───────────────────────────────────────────
_FN3="$_SW_FIX/n3"; _mk_nexus "$_FN3"
_sw_out3=$(_run_spawn "$_FN3" -n victim-sk3 -c "$_SW_FIX" -p "$WORK/reports/promo.md" \
    --skeptic-role --skeptic-target victimwin)
assert_eq "NO -r: the marker is still written (the gate must shut regardless)" \
    "$( [[ -e "$_FN3/monitor/.state/skeptic/pending/victimwin" ]] && echo yes || echo no)" "yes"
assert_contains "NO -r: and it SAYS the arm records no subject" \
    "$_sw_out3" "records NO SUBJECT"
assert_eq "NO -r: and no arm row is invented" \
    "$(_arms_on "$_FN3" victimwin | grep -c .)" "0"

# ── 5d. NO -r BUT THE LEDGER ALREADY HOLDS AN ARM (your-org/nexus-code#1302) ─
#
# The protocol's NORMAL path: the target's own `require` wrap-up armed its key
# with its own report's sha before the orchestrator ever spawned. The warning
# above reasons about ITS OWN ARGUMENT (`-r` absent) and used to report that as
# a property of the LEDGER — so it fired on the common case, and, its text
# being identical either way, left no way to recognise the genuine one.
_FN4="$_SW_FIX/n4"; _mk_nexus "$_FN4"
NEXUS_ROOT="$_FN4" "$NG" skeptic-arm victimwin --report "$_FN4/reports/victim.md" \
    --state-dir "$_FN4/monitor/.state" >/dev/null 2>&1
assert_eq "#1302 FIXTURE: the ledger really does hold an outstanding arm" \
    "$(_arms_on "$_FN4" victimwin | grep -c .)" "1"
_sw_out4=$(_run_spawn "$_FN4" -n victim-sk4 -c "$_SW_FIX" -p "$WORK/reports/promo.md" \
    --skeptic-role --skeptic-target victimwin)
assert_contains "#1302 POSITIVE CONTROL: the spawn ran to completion" \
    "$_sw_out4" "spawned: window=victim-sk4"
assert_not_contains "#1302 an OUTSTANDING arm is not reported as NO SUBJECT" \
    "$_sw_out4" "records NO SUBJECT"
assert_contains "#1302 …the ledger is CONSULTED and its answer is quoted" \
    "$_sw_out4" "outstanding=1"

# ── 5e. AN ALREADY-OUTSTANDING ARM MUST NOT ABORT THE SPAWN ─────────────────
#
# `ng skeptic-arm` returns 3 for "already outstanding", which its own header
# calls "the normal first-pass outcome". Under `set -euo pipefail` a bare
# `out=$(cmd)` capture makes that rc FATAL: the `case` that handles it never
# runs. Measured pre-fix — the window was created and the launcher sent, then
# spawn-worker exited 3 without its `spawned:` line.
_FN5="$_SW_FIX/n5"; _mk_nexus "$_FN5"
NEXUS_ROOT="$_FN5" "$NG" skeptic-arm victimwin --report "$_FN5/reports/victim.md" \
    --state-dir "$_FN5/monitor/.state" >/dev/null 2>&1
_sw_out5=$(_run_spawn "$_FN5" -n victim-sk5 -c "$_SW_FIX" -p "$WORK/reports/promo.md" \
    -r "$_FN5/reports/victim.md" --skeptic-role --skeptic-target victimwin); _sw_rc5=$?
assert_eq "#1302 rc 3 from skeptic-arm is NOT fatal: the spawn exits 0" "$_sw_rc5" "0"
assert_contains "#1302 …and the machine-readable success line is printed" \
    "$_sw_out5" "spawned: window=victim-sk5"
assert_eq "#1302 …and no duplicate arm was appended" \
    "$(_arms_on "$_FN5" victimwin | grep -c .)" "1"

# ── 5f. #1252 A: narrow the ambiguity by ISSUE, the key the file already uses ─
#
# `_skeptic_open_arms` treats a deliverable as (issue, path) and
# `_skeptic_open_arm_for_path` filters on issue. The ambiguity arm did NOT: it
# counted every open arm on the WINDOW key. Window names are reused — measured
# 916 of 2319 distinct spawned names on this board — so a round-3 skeptic
# delivering a correct verdict attributed NOTHING, because two dead rounds were
# still open on the same name.
_open_n() {   # _open_n <key>
    { sed -n '/^_skeptic_ledger_file()/,/^}/p' "$NG"
      sed -n '/^_skeptic_open_arms()/,/^}/p'   "$NG"
      printf '_skeptic_open_arms %q %q\n' "$PEND" "$1"; } | bash | grep -c .
}
for _r in alpha:100 beta:200 gamma:300; do
    printf 'round %s body\n' "${_r%%:*}" > "$WORK/reports/${_r%%:*}.md"
    "$NG" skeptic-arm reused --report "$WORK/reports/${_r%%:*}.md" --issue "${_r##*:}" \
        --state-dir "$STATE" >/dev/null 2>&1
done
assert_eq "#1252 FIXTURE: three rounds are outstanding on ONE reused window name" \
    "$(_open_n reused)" "3"
_drive reused credible 300 sk-gamma ""
assert_contains "#1252 A: the discharge is attributed by ISSUE, not left ambiguous" \
    "$(tail -1 "$PEND/.reused.ledger")" "attributed-by-issue"
assert_eq "#1252 A: …and it closes exactly ONE arm, so the gate still refuses" \
    "$(_open_n reused)" "2"

# NEG CONTROL — the mutation-sensitive one. TWO arms under ONE issue must stay
# ambiguous: this is what a naive window-keyed newest-wins would break, and it
# is the shape `#984`/`#963` forbid resolving by inference.
printf 'same-issue b\n' > "$WORK/reports/si-b.md"
printf 'same-issue c\n' > "$WORK/reports/si-c.md"
"$NG" skeptic-arm sameiss --report "$WORK/reports/si-b.md" --issue 984 --state-dir "$STATE" >/dev/null 2>&1
"$NG" skeptic-arm sameiss --report "$WORK/reports/si-c.md" --issue 984 --state-dir "$STATE" >/dev/null 2>&1
assert_eq "#1252 NEG CTL FIXTURE: two arms, one issue" "$(_open_n sameiss)" "2"
_drive sameiss credible 984 sk-si ""
assert_contains "#1252 NEG CTL: two arms on ONE issue stay AMBIGUOUS" \
    "$(tail -1 "$PEND/.sameiss.ledger")" "ambiguous-2-arms-outstanding"
assert_eq "#1252 NEG CTL: …and close NEITHER arm" "$(_open_n sameiss)" "2"

# NEG CONTROL — a discharge whose issue matches NO open arm must not narrow.
printf 'nomatch a\n' > "$WORK/reports/nm-a.md"
printf 'nomatch b\n' > "$WORK/reports/nm-b.md"
"$NG" skeptic-arm nomatch --report "$WORK/reports/nm-a.md" --issue 111 --state-dir "$STATE" >/dev/null 2>&1
"$NG" skeptic-arm nomatch --report "$WORK/reports/nm-b.md" --issue 222 --state-dir "$STATE" >/dev/null 2>&1
_drive nomatch credible 999 sk-nm ""
assert_contains "#1252 NEG CTL: a discharge issue matching NO arm stays ambiguous" \
    "$(tail -1 "$PEND/.nomatch.ledger")" "ambiguous-2-arms-outstanding"

# ═══ 6. #1190 — SETTLING THE EDGE DOES NOT RELEASE THE COUNTERPART ══════════
#
# `skeptic-channel.sh close` is the SOLE writer of the DONE sentinel, so
# `obligations.sh settle` cannot release a counterpart sitting in `await`. The
# reporter of #1190 ran `close` BEFORE `settle` and could not tell which verb
# wrote the sentinel; this pins the answer structurally rather than by ordering
# an experiment.
# ── THE PROPERTY IS BEHAVIOURAL, SO TEST IT BEHAVIOURALLY
#    (your-org/nexus-code#1207 skeptic F2) ──────────────────────────────────
#
# The first version of this counted uses of the `_done_sentinel` ACCESSOR. THE
# REAL WRITER DOES NOT USE IT: `cmd_close` builds `"$dir/DONE"` literally
# (skeptic-channel.sh:1037) and calls the accessor nowhere, so the two
# non-comment sites it found were the DEFINITION (:401) and the READER in
# `await` (:761) — while the write-up called them "the writer in close and the
# reader in await". A census that names the wrong two things and reports the
# right TOTAL is `#946`'s shape: agreement is not verification.
#
# The second attempt keyed on the sentinel PATH plus a write construct on the
# same line. That returned EMPTY, and its positive control caught it: the write
# is `mv -f "$tmp" "$sentinel"`, indirected through a variable, so no `/DONE"`
# appears on the writing line at all. Two failed static predicates is the signal
# to stop writing predicates.
#
# The claim `_settle_channel_notice` makes is BEHAVIOURAL — *settling does not
# release the counterpart* — so it is tested by SETTLING and looking. Planting
# `: > "$chan/DONE"` into that function is exactly the shape `cmd_close` uses,
# and it reddens this while both static censuses stayed green.
_ob_state="$WORK/obl-state"
mkdir -p "$_ob_state/skeptic/pending" "$_ob_state/skeptic/creditorwin" "$_ob_state/obligations"
_ob() { env NEXUS_STATE_DIR="$_ob_state" bash "$OBLIG" "$@"; }
_ob open --debtor debtorwin --creditor creditorwin --kind skeptic-verdict >/dev/null 2>&1
# POSITIVE CONTROL: the edge must actually exist, or "no DONE appeared" is a
# statement about a settle that never ran.
assert_eq "POSITIVE CONTROL: an obligation edge was opened" \
    "$( [[ -n "$(ls -1 "$_ob_state/obligations" 2>/dev/null)" ]] && echo yes || echo no)" "yes"
assert_no_file "PRECONDITION: the creditor's channel has no DONE sentinel" \
    "$_ob_state/skeptic/creditorwin/DONE"
_ob_out=$(_ob settle --debtor debtorwin \
    --reason "the verdict landed on the round-1 report; recording it here for the audit trail" 2>&1)
assert_contains "POSITIVE CONTROL: the settle actually reported settling" \
    "$_ob_out" "settled"
# THE PROPERTY: settling must not create the sentinel that releases `await`.
assert_no_file "SETTLING WRITES NO DONE SENTINEL — await is not released by it" \
    "$_ob_state/skeptic/creditorwin/DONE"
assert_contains "…and it SAYS so on stderr rather than leaving it implicit" \
    "$_ob_out" "did NOT release it"

assert_contains "…and names the verb that does" \
    "$(sed -n '/_settle_channel_notice()/,/^}/p' "$OBLIG")" "skeptic close"
# The notice must only claim an open channel when the absence was POSITIVELY
# OBSERVED — an unreadable channel dir is a failure to look, not a finding.
assert_contains "…and only claims it on a channel dir it could actually read" \
    "$(sed -n '/_settle_channel_notice()/,/^}/p' "$OBLIG")" '[[ -d "$chan" && -r "$chan" ]] || return 0'


# ═══ #1156 — THE DELIVERABLE IS A PATH; THE HASH IS EVIDENCE ════════════════
#
# The ledger keyed a round by the report's CONTENT HASH while the thing a
# skeptic reviews is a report AT A PATH that the worker keeps editing. Any edit
# between arming and discharge moved the hash off the arm, and the verdict then
# rendered as outstanding in one of two ways, NEITHER distinguishable from a
# skeptic that never answered:
#
#   pole A  `ambiguous-N-arms-outstanding` — N wrap-up runs armed N rounds
#           against ONE path; one discharge cannot close N arms.
#   pole B  `asserted-not-armed` — the report was amended after a single arm,
#           so the reviewer's own `--skeptic-subject` named bytes nobody armed.
#
# Both are driven through the REAL writer here, not asserted from a fixture.
_drive_p() {   # _drive_p <key> <verdict> <issue> <by> <asserted-sha> <asserted-path>
    { sed -n '/^_skeptic_ledger_file()/,/^}/p'        "$NG"
      sed -n '/^_skeptic_artefact_sha()/,/^}/p'       "$NG"
      sed -n '/^_skeptic_record_arm()/,/^}/p'         "$NG"
      sed -n '/^_skeptic_open_arms()/,/^}/p'          "$NG"
      sed -n '/^_skeptic_open_arm_for_path()/,/^}/p'  "$NG"
      sed -n '/^_skeptic_record_discharge()/,/^}/p'   "$NG"
      printf '_skeptic_record_discharge %q %q %q %q %q %q %q\n' \
          "$PEND" "$1" "$2" "$3" "$4" "${5:-}" "${6:-}"
    } | bash
}
_open_n() {    # _open_n <key> -> how many arms are still outstanding
    { sed -n '/^_skeptic_ledger_file()/,/^}/p' "$NG"
      sed -n '/^_skeptic_open_arms()/,/^}/p'   "$NG"
      printf '_skeptic_open_arms %q %q\n' "$PEND" "$1"
    } | bash 2>/dev/null | grep -c . || true
}
_H() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
_armrow() {    # _armrow <key> <sha> <issue> <path>
    printf 'armed\t%s\t2026-08-28T01:00:00\t%s\t%s\n' "$2" "$3" "$4" >> "$PEND/.$1.ledger"
}

# ── THE SUPERSESSION RULE, AND THE THREE THINGS IT MUST NOT DO ─────────────
# A later arm on the same (issue, path) REPLACES the earlier open arm. The
# three negative controls are the whole safety argument: the rule must key on
# the DELIVERABLE, never on the window, or it silently closes an obligation
# for an artefact nobody reviewed (the `#963`/`#984` sequence).
_armrow s1156a "$(_H a1)" 339 /r/same.md
_armrow s1156a "$(_H a2)" 339 /r/same.md
_armrow s1156a "$(_H a3)" 339 /r/same.md
assert_eq "#1156 pole A: three arms on ONE deliverable are ONE open arm" \
    "$(_open_n s1156a)" "1"

_armrow s1156b "$(_H b1)" 339 /r/a.md
_armrow s1156b "$(_H b2)" 339 /r/b.md
_armrow s1156b "$(_H b3)" 339 /r/c.md
assert_eq "#1156 NEG CTL: DIFFERENT paths stay distinct — ambiguity is the honest answer" \
    "$(_open_n s1156b)" "3"

_armrow s1156c "$(_H c1)" 984 /r/same.md
_armrow s1156c "$(_H c2)" 985 /r/same.md
assert_eq "#1156 NEG CTL: same path on a DIFFERENT ISSUE is a different deliverable" \
    "$(_open_n s1156c)" "2"

_armrow s1156d "$(_H d1)" 339 -
_armrow s1156d "$(_H d2)" 339 -
assert_eq "#1156 NEG CTL: arms with NO path recorded supersede nothing" \
    "$(_open_n s1156d)" "2"

# ── POLE A, END TO END THROUGH THE WRITER ──────────────────────────────────
_drive_p s1156a check 339 sk-a "" ""
assert_contains "#1156 pole A: the discharge now ATTRIBUTES instead of going ambiguous" \
    "$(cat "$PEND/.s1156a.ledger")" "attributed"
assert_eq "#1156 pole A: …and the obligation is closed" "$(_open_n s1156a)" "0"

# ── POLE B: THE REPORT WAS AMENDED AFTER ARMING ────────────────────────────
# The reviewer asserts the PATH it read. Pre-fix this recorded
# `asserted-not-armed` and closed nothing.
_armrow s1156e "$(_H orig)" 339 /r/amended.md
_drive_p s1156e check 339 sk-e "$(_H amended)" /r/amended.md
_e_row=$(awk -F'\t' '$1=="discharged"{l=$0} END{print l}' "$PEND/.s1156e.ledger")
assert_contains "#1156 pole B: a PATH assertion against a drifted arm is attributed" \
    "$_e_row" "asserted-path"
assert_eq "#1156 pole B: …and it CLOSES the arm" "$(_open_n s1156e)" "0"
# It closes by the SAME 64-hex construction every other reader relies on:
# field 2 must be the ARMED sha, never the reviewer's drifted one.
assert_eq "#1156 pole B: …field 2 is the ARMED sha, so no reader learns a new rule" \
    "$(printf '%s' "$_e_row" | awk -F'\t' '{print $2}')" "$(_H orig)"
# The drift is EVIDENCE and must survive on the record — this issue is about
# states that render identically, so the row may not look like a clean match.
assert_eq "#1156 pole B: …field 8 carries the hash the REVIEWER held" \
    "$(printf '%s' "$_e_row" | awk -F'\t' '{print $8}')" "$(_H amended)"

# ── THE THREE REFUSALS. A path assertion is not a skeleton key. ────────────
_armrow s1156f "$(_H f1)" 984 /r/f.md
_drive_p s1156f check 985 sk-f "$(_H f2)" /r/f.md
assert_contains "#1156 NEG CTL: a path armed on ANOTHER issue is still not-armed" \
    "$(cat "$PEND/.s1156f.ledger")" "asserted-not-armed"

_armrow s1156g "$(_H g1)" 339 /r/g.md
_drive_p s1156g check 339 sk-g "$(_H gx)" /r/NEVER-ARMED.md
assert_contains "#1156 NEG CTL: a path NOBODY armed is still not-armed" \
    "$(cat "$PEND/.s1156g.ledger")" "asserted-not-armed"

# A reviewer that asserted a bare SHA made a CONTENT claim; it is left exactly
# as it was, at the original arity.
_armrow s1156h "$(_H h1)" 339 /r/h.md
_drive_p s1156h check 339 sk-h "$(_H h2)" ""
_h_row=$(awk -F'\t' '$1=="discharged"{l=$0} END{print l}' "$PEND/.s1156h.ledger")
assert_contains "#1156 NEG CTL: a bare-SHA assertion is unchanged" \
    "$_h_row" "asserted-not-armed"
assert_eq "#1156 NEG CTL: …and stays at 7 fields" \
    "$(printf '%s' "$_h_row" | awk -F'\t' '{print NF}')" "7"

# POSITIVE CONTROL for the arity rule: an UNDRIFTED path assertion is the plain
# old `asserted` at 7 fields. If this ever reads `asserted-path`, the new arm is
# firing on the happy path and the classes have stopped discriminating.
_armrow s1156i "$(_H i1)" 339 /r/i.md
_drive_p s1156i check 339 sk-i "$(_H i1)" /r/i.md
_i_row=$(awk -F'\t' '$1=="discharged"{l=$0} END{print l}' "$PEND/.s1156i.ledger")
assert_eq "#1156 POS CTL: an UNDRIFTED path assertion is plain \`asserted\`" \
    "$(printf '%s' "$_i_row" | awk -F'\t' '{print $7}')" "asserted"
assert_eq "#1156 POS CTL: …at the original 7 fields" \
    "$(printf '%s' "$_i_row" | awk -F'\t' '{print NF}')" "7"

# ── THE CLASSIFIER MUST AGREE WITH THE WRITER ──────────────────────────────
# A new detail value falls to `unmatched_other` by default, which reports
# "whether it matches is UNESTABLISHED" about a row that establishes it. The
# renderer is what an operator reads, so the agreement is asserted THROUGH it.
_ev_1156=$(_ev s1156e)
assert_contains "#1156 the RENDERER counts an asserted-path row as MATCHED" \
    "$_ev_1156" "matched=1"
assert_contains "#1156 …and reports nothing outstanding" \
    "$_ev_1156" "open=0"


# ── THE TWO SCANS OF "WHICH ARMS ARE OPEN" MUST AGREE ──────────────────────
# `_skeptic_open_arms` and `_skeptic_verdict_evidence` answer the same question
# with SEPARATE awk programs. #1156's first cut taught only the function to
# collapse revisions of one deliverable, so the function said 1 while the
# RENDERER said 3 — and the renderer is what `retire-preflight` and the kill
# gate read, so the operator-visible symptom would have survived its own fix.
# Asserted on every shape above, not just the one that motivated it: an
# agreement pinned on a single fixture is pinned on the fixture, not the rule.
for _k in s1156a s1156b s1156c s1156d s1156e; do
    _fn_open=$(_open_n "$_k")
    _rd_open=$(_field "$(_ev "$_k")" open)
    assert_eq "#1156 AGREEMENT on \`$_k\`: the function and the RENDERER count the same open arms" \
        "$_fn_open" "$_rd_open"
done




# ═══ #1251 — THE CANONICAL SPAWN COMMAND MUST CARRY `-r` ════════════════════
#
# `spawn-worker.sh --skeptic-role` establishes the armed state, and for a
# SECOND-or-later pass it is the ONLY writer that does — the verdict that
# recommended the next round cleared every marker on its way out. `-r` is the
# only thing that gives that arm a SUBJECT. Without it the marker is written
# alone, no `armed` row is appended, the verdict lands `no-arm-on-record`, and
# NOTHING LATER CAN REPAIR IT: `noarm` outranks `attributed` and the ledger is
# append-only, so `retire-preflight`'s "the repair is to the ARM" is
# unperformable. Arm time is the only repairable moment, so the flag belongs in
# the command rather than in advice beside it.
mkdir -p "$WORK/r1251"; printf 'the report\n' > "$WORK/r1251/w.md"
_cmd1251=$( cd "$WORK/r1251" && _SK_REPORT_PATH=w.md bash -c '
    source '"$NG"' >/dev/null 2>&1
    _SK_REPORT_PATH=w.md _skeptic_spawn_cmd victimwin 1' 2>/dev/null )
# POSITIVE CONTROL: the emitter ran at all. Every "contains" below is a false
# pass on empty output without it.
assert_contains "#1251 POSITIVE CONTROL: the spawn command was emitted" \
    "$_cmd1251" "spawn-worker.sh -n victimwin-skeptic"
assert_contains "#1251 the emitted command carries -r" "$_cmd1251" " -r "
# ABSOLUTISED: the ORCHESTRATOR runs this from its own cwd, not the worker's, so
# a relative path in the emit is a path that resolves somewhere else.
assert_contains "#1251 …with the report ABSOLUTISED, not as given" \
    "$_cmd1251" " -r $WORK/r1251/w.md"
# The RECURSIVE branch is the one with no other arm writer, so it is asserted
# separately rather than assumed to share the line.
_cmdr1251=$( cd "$WORK/r1251" && bash -c '
    source '"$NG"' >/dev/null 2>&1
    _SK_REPORT_PATH=w.md _skeptic_spawn_cmd victimwin 2 rootwin' 2>/dev/null )
assert_contains "#1251 the RECURSIVE branch carries -r too" "$_cmdr1251" " -r $WORK/r1251/w.md"
assert_contains "#1251 …and is still the recursive shape" "$_cmdr1251" "--skeptic-orig rootwin"

# NO SUBJECT AVAILABLE => a LOUD PLACEHOLDER, never a dropped flag. An
# unreadable `-r` exits 9 and says so; an ABSENT `-r` produces exactly the
# silent subject-less arm this block exists to prevent.
_cmdp1251=$( bash -c 'source '"$NG"' >/dev/null 2>&1
    unset _SK_REPORT_PATH; _skeptic_spawn_cmd victimwin 1' 2>/dev/null )
assert_contains "#1251 with no report in scope the flag is KEPT as a placeholder" \
    "$_cmdp1251" " -r <report-the-skeptic-must-read>"
assert_contains "#1251 …and the emit says why it must not be dropped" \
    "$_cmdp1251" "records NO SUBJECT"

# THE BEHAVIOURAL HALF. A text assertion on the emit cannot tell a flag that
# WORKS from one that merely appears — this suite's own history has a text proxy
# passing green over a fix that recorded nothing. So run the real
# `spawn-worker.sh` with the placeholder and assert it FAILS CLOSED: rc 9, and
# it must never reach tmux. A stub tmux is first on PATH, and its call count is
# the evidence.
_sb1251="$WORK/sb1251"; mkdir -p "$_sb1251"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/tmux.calls"\nexit 0\n' "$_sb1251" > "$_sb1251/tmux"
chmod +x "$_sb1251/tmux"; : > "$_sb1251/tmux.calls"
# A CLAUDE STUB, AND CLAUDE_BIN POINTED AT IT (your-org/nexus-code#1251 CI red).
#
# `spawn-worker.sh:773` sources `_claude-bin.sh` UNCONDITIONALLY, at top level,
# and that resolver `exit 1`s when it finds neither `$NEXUS_ROOT/node_modules/
# .bin/claude` nor `claude` on PATH. Line 773 is a long way above the `-r`
# check at `:2020`, so on a host with no `claude` this assertion measured
# CLAUDE RESOLUTION and not the `-r` gate it is about: rc 1, want 9.
#
# GitHub-hosted runners are exactly that host — no `node_modules/` (gitignored,
# and `tests.yml` has no install step) and no `claude` on PATH, which
# `tests.yml:784-785` already says in its own words while justifying a
# different step's SKIP tolerance. So this assertion has been red in CI in
# every band since it landed in `82c66dbe`, and it is UNREPRODUCIBLE on an
# operator box: `#577` re-roots NEXUS_ROOT to the PRIMARY, whose
# `node_modules/.bin/claude` always resolves. Measured in a `node_modules`-free
# worktree, one variable:
#
#     no CLAUDE_BIN   -> rc 1   dies in _claude-bin.sh
#     CLAUDE_BIN=stub -> rc 9   "prior-report not readable (-r)"
#
# Arm 1 of the resolver is the env override, so pinning it short-circuits
# before either filesystem probe and the case behaves identically on both
# hosts. The stub is never EXECUTED — spawn-worker fails closed on `-r` long
# before it would exec anything — so this buys determinism, not a live spawn.
#
# IT ALSO DE-VACUIFIES ITS OWN COMPANION. The `tmux.calls == 0` assertion below
# PASSED in CI for the wrong reason: spawn-worker never reached tmux because it
# died at claude resolution, not because it fail-closed on `-r`. A vacuous pass
# sitting next to the red, in the same block.
printf '#!/usr/bin/env bash\nexit 0\n' > "$_sb1251/claude"; chmod +x "$_sb1251/claude"
# POSITIVE CONTROL, so the pin cannot silently rot back into measuring
# resolution: assert the resolver actually takes the stub, under the SAME env
# the invocation below uses. Without this, a future change to `_claude-bin.sh`'s
# precedence would return this case to rc 1 with nothing saying so.
_cb1251=$(CLAUDE_BIN="$_sb1251/claude" NEXUS_ROOT="$WORK/nonexistent-root" \
    bash -c '. "$1" >/dev/null 2>&1; printf %s "${CLAUDE_BIN:-}"' _ \
    "$REPO_ROOT/monitor/_claude-bin.sh" 2>/dev/null)
assert_eq "#1251 POSITIVE CONTROL: _claude-bin.sh resolves to the fixture stub" \
    "$_cb1251" "$_sb1251/claude"
CLAUDE_BIN="$_sb1251/claude" PATH="$_sb1251:$PATH" timeout 60 "$(dirname "$NG")/spawn-worker.sh" \
    -n zz1251-skeptic -c "$WORK/r1251" -p /dev/null \
    -r '<report-the-skeptic-must-read>' \
    --skeptic-role --skeptic-target zz1251 --skeptic-depth 1 >/dev/null 2>&1
assert_eq "#1251 BEHAVIOUR: the placeholder makes spawn-worker fail CLOSED (rc 9)" "$?" "9"
assert_eq "#1251 …and it never reached tmux, so no window and no marker" \
    "$(wc -l < "$_sb1251/tmux.calls" | tr -d ' ')" "0"

# ── ANTI-REGRESSION: SUPERSEDING MUST NOT DISBELIEVE THE REVIEWER (#1230) ───
# The supersede rule subtracts older revisions of a deliverable, which is right
# for COUNTING what is owed and wrong for judging a reviewer's ASSERTION. A
# reviewer that read r1 while the worker re-wrapped r2 asserts r1 honestly, and
# r1 is exactly what the subtraction hides — so the first cut of #1156 turned
# `asserted` into `asserted-not-armed` on the #963 sequence it exists to
# protect, converting its own pole A into its own pole B.
#
# Caught by a sibling agent measuring #1230 against the in-flight patch, NOT by
# this suite as it then stood. That is why the assertion below is the pair
# (detail AND outstanding) rather than the detail alone: outstanding is
# unchanged in both directions, so a guard watching only the count sees nothing.
_armrow s1156j "$(_H j1)" 339 /r/j.md
_armrow s1156j "$(_H j2)" 339 /r/j.md
_drive_p s1156j check 339 sk-j "$(_H j1)" ""
_j_row=$(awk -F'\t' '$1=="discharged"{l=$0} END{print l}' "$PEND/.s1156j.ledger")
assert_eq "#1230 a reviewer asserting the SUPERSEDED revision it read is BELIEVED" \
    "$(printf '%s' "$_j_row" | awk -F'\t' '{print $7}')" "asserted"
# …and the deliverable STAYS outstanding, because r2 holds work nobody reviewed.
# This is the #963 safety direction and it must survive the supersede rule.
assert_eq "#1230 …and the NEWER revision stays outstanding — nobody reviewed it" \
    "$(_open_n s1156j)" "1"
# NEGATIVE CONTROL: the wider set is the PRE-supersede OPEN set, not "every sha
# ever written". An artefact already discharged, asserted a second time, is
# still refused exactly as before the supersede rule existed.
_armrow s1156k "$(_H k1)" 339 /r/k.md
_drive_p s1156k check 339 sk-k "$(_H k1)" ""
_drive_p s1156k credible 339 sk-k "$(_H k1)" ""
assert_eq "#1230 NEG CTL: an ALREADY-DISCHARGED artefact asserted again is still refused" \
    "$(awk -F'\t' '$1=="discharged"{l=$7} END{print l}' "$PEND/.s1156k.ledger")" "asserted-not-armed"

# ═══ #1253 — THE `0:k` BANNER MUST BE TRUE OF THE STATE THAT TRIGGERS IT ════
#
# The wrap-up banner's `0:k` arm said "no ledger exists … nothing ever armed it
# … will report evidence=none". Driven against the ONLY state that reaches it —
# a ledger that EXISTS, holds an arm and a prior verdict, and cannot be written
# — all three clauses were false, while `ng skeptic-evidence` independently
# reported an attributed round. `0:k` means the APPEND FAILED, not that nothing
# was armed: since #1207 both nothing-outstanding shapes are written, and
# `_skeptic_record_discharge`'s one early return is unreachable from this call
# site.
#
# Asserted as OUTPUT-vs-STATE, never string-vs-string: a reworded comment
# cannot make this pass, only a printed diagnosis that is true.
_st1253="$WORK/st1253"; _p1253="$_st1253/skeptic/pending"
mkdir -p "$_p1253"
_l1253="$_p1253/.T1253.ledger"
_h1253=$(printf 't1\n' | sha256sum | awk '{print $1}')
printf 'armed\t%s\t2026-09-01T01:00:00\t50\t/r/t.md\n' "$_h1253" >  "$_l1253"
printf 'discharged\t%s\t2026-09-01T01:30:00\tcheck\t50\tsk\tattributed\n' "$_h1253" >> "$_l1253"
: > "$_p1253/T1253"
chmod a-w "$_l1253"

# GUARD ON THE GUARD. `chmod a-w` does not stop root, and a suite that silently
# skips its own subject is the failure this repo keeps filing. If the file is
# still writable the arm is UNTESTABLE here and must say so loudly, never pass.
if : 2>/dev/null >>"$_l1253"; then
    assert_eq "#1253 PRECONDITION: the ledger is genuinely unwritable (running as root?)" \
        "writable-cannot-test" "unwritable"
else
    _out1253=$( { sed -n '/^_skeptic_ledger_file()/,/^}/p'      "$NG"
                  sed -n '/^_skeptic_open_arms()/,/^}/p'        "$NG"
                  sed -n '/^_skeptic_open_arm_for_path()/,/^}/p' "$NG"
                  sed -n '/^_skeptic_record_discharge()/,/^}/p' "$NG"
                  printf 'pending_dir=%q; _sk_reviewed_key=T1253; reviewed=T1253\n' "$_p1253"
                  printf '_skeptic_record_discharge %q T1253 credible 50 sk "" ""\n' "$_p1253"
                  # the banner arm, reproduced from ng by the same extraction the
                  # rest of this suite uses, so it cannot drift from the source
                  printf 'case "${_SK_DISCHARGE_RECORDED:-0}:${_sk_reviewed_key:+k}" in\n'
                  sed -n '/^            0:k) printf .ledger  /,/re-run this wrap-up/p' "$NG"
                  printf '\nesac\n'
                } | bash 2>/dev/null )
    # POSITIVE CONTROL: the arm actually ran. Without this, every "does not
    # contain" below passes on empty output — a false zero.
    assert_contains "#1253 POSITIVE CONTROL: the 0:k arm was actually reached" \
        "$_out1253" "NOT RECORDED"
    # THE PROPERTY, in both directions.
    assert_not_contains "#1253 the banner does NOT claim the ledger is absent" \
        "$_out1253" "no ledger exists"
    assert_not_contains "#1253 …nor that nothing ever armed the key" \
        "$_out1253" "ever armed it"
    assert_not_contains "#1253 …nor predicts evidence=none" \
        "$_out1253" "evidence=none"
    # …and it names the ACTUAL file, so the operator can go and fix it.
    assert_contains "#1253 …and it names the ledger path that failed" \
        "$_out1253" "$_l1253"
    # THE STATE, read independently. This is what makes the four assertions
    # above claims about REALITY rather than about wording: the ledger the
    # banner must not call absent is right here, and the evidence class the
    # banner must not predict as `none` is measured to be something else.
    assert_eq "#1253 STATE: the ledger the banner must not call absent DOES exist" \
        "$( [[ -e "$_l1253" ]] && echo present || echo ABSENT)" "present"
    _ev1253=$("$NG" skeptic-evidence T1253 --state-dir "$_st1253" 2>/dev/null | sed -n 1p)
    assert_eq "#1253 STATE: …and its evidence class is NOT none" \
        "$( [[ "$(_field "$_ev1253" evidence)" == "none" ]] && echo none || echo not-none)" "not-none"
fi
chmod u+w "$_l1253" 2>/dev/null || true

# ═══ 6. THE DISCHARGE IS IDEMPOTENT WITHIN A ROUND — AND ONLY WITHIN A ROUND
#        (your-org/nexus-code#1370, carrying #1366's negative control) ═══════
#
# `_skeptic_record_discharge` appended UNCONDITIONALLY. Three identical
# `ng wrap-up` invocations (two of them attempts to re-read truncated output)
# wrote three rows on `.warm.ledger`, and identical re-recordings can neither
# supersede nor be superseded, so `unmatched` became permanent and
# last-write-wins made the `sha=-` row the STANDING one over the attributed
# row that carried the evidence.
#
# THE NEGATIVE CONTROL IS THE LOAD-BEARING HALF. A dedup on (verdict, issue,
# by) alone — or on adjacency, or on a time window — looks equivalent and
# silently destroys a real second verdict; the ledger then reads CLEANER,
# which is the failure direction that survives review. So: a re-arm between
# two discharges MUST still yield two rows, whether the re-arm carries a
# different sha (a different tuple) or the SAME sha (the arm re-opens and
# needs a fresh discharge to close it).
_ledger_disch_count() { grep -c '^discharged' "$PEND/.$1.ledger" 2>/dev/null || true; }
_open_arms_count() {
    { sed -n '/^_skeptic_ledger_file()/,/^}/p' "$NG"
      sed -n '/^_skeptic_open_arms()/,/^}/p'   "$NG"
      printf '_skeptic_open_arms %q %q | grep -c .\n' "$PEND" "$1"; } | bash
}
printf 'idem r1\n' > "$WORK/reports/idem.md"
"$NG" skeptic-arm idem --report "$WORK/reports/idem.md" --issue 1370 \
    --state-dir "$STATE" >/dev/null 2>&1
_drive idem check 1370 sk-idem ""
assert_eq "#1370 POSITIVE CONTROL: the first discharge is recorded" "$(_ledger_disch_count idem)" "1"
_drive idem check 1370 sk-idem ""
_drive idem check 1370 sk-idem ""
assert_eq "#1370 THE PROPERTY: two identical re-runs append NO further row" \
    "$(_ledger_disch_count idem)" "1"
assert_eq "#1370 …and the arm they would have re-closed stays closed (open=0)" \
    "$(_open_arms_count idem)" "0"
# What the caller is told: the verdict IS on record, and the detail names the
# row it duplicates rather than claiming a fresh append.
_dup_out=$( { sed -n '/^_skeptic_ledger_file()/,/^}/p' "$NG"; sed -n '/^_skeptic_artefact_sha()/,/^}/p' "$NG"
              sed -n '/^_skeptic_record_arm()/,/^}/p' "$NG"; sed -n '/^_skeptic_open_arms()/,/^}/p' "$NG"
              sed -n '/^_skeptic_open_arms_for_issue()/,/^}/p' "$NG"; sed -n '/^_skeptic_record_discharge()/,/^}/p' "$NG"
              printf '_skeptic_record_discharge %q idem check 1370 sk-idem ""; echo "R=$_SK_DISCHARGE_RECORDED D=$_SK_DISCHARGE_DETAIL"\n' "$PEND"; } | bash )
assert_contains "#1370 …the caller sees RECORDED=1 (a matching row exists)" "$_dup_out" "R=1"
assert_contains "#1370 …with a detail naming the duplicated row" "$_dup_out" "D=already-recorded:attributed"
# #1366 NEGATIVE CONTROL (a): re-arm with a DIFFERENT sha -> a new tuple -> TWO rows.
printf 'idem r2\n' > "$WORK/reports/idem.md"
"$NG" skeptic-arm idem --report "$WORK/reports/idem.md" --issue 1370 \
    --state-dir "$STATE" >/dev/null 2>&1
_drive idem check 1370 sk-idem ""
assert_eq "#1366 NEGATIVE CONTROL: a re-arm (different sha) between two discharges yields TWO rows" \
    "$(_ledger_disch_count idem)" "2"
assert_eq "#1366 …and closes the new arm (open=0)" "$(_open_arms_count idem)" "0"
# #1366 NEGATIVE CONTROL (b): re-arm with the SAME sha (same bytes re-wrapped). The
# tuple is identical to the row above, so a tuple-only dedup would skip it and
# leave the re-opened arm outstanding forever. The round boundary is what
# makes it append.
"$NG" skeptic-arm idem --report "$WORK/reports/idem.md" --issue 1370 \
    --state-dir "$STATE" >/dev/null 2>&1
assert_eq "#1366 PRECONDITION: the same-sha re-arm re-opened the arm (open=1)" \
    "$(_open_arms_count idem)" "1"
_drive idem check 1370 sk-idem ""
assert_eq "#1366 NEGATIVE CONTROL: a SAME-sha re-arm still gets its own discharge row (3)" \
    "$(_ledger_disch_count idem)" "3"
assert_eq "#1366 …and that row closes the re-opened arm (open=0)" "$(_open_arms_count idem)" "0"
# A `resolved` row is a round boundary too: an identical verdict after an
# audited release is a new statement, not a re-run.
# Written in the row shape `ng skeptic resolve` writes (`resolved<TAB>-<TAB>ts…`)
# rather than through the verb, which is operator-gated and marker-dependent —
# the WRITER's boundary rule is what is under test here, not the verb.
printf 'resolved\t-\t2026-09-03T00:00:00\tround closed by hand for the #1370 control\t-\n' >> "$PEND/.idem.ledger"
_drive idem check 1370 sk-idem ""
assert_eq "#1370 CONTROL: an identical verdict AFTER a \`resolved\` row is appended (4)" \
    "$(_ledger_disch_count idem)" "4"
# A DIFFERENT verdict, same round, is never a duplicate — it is the
# supersession case `_skeptic_verdict_evidence` exists to rank.
printf 'idem2\n' > "$WORK/reports/idem2.md"
"$NG" skeptic-arm idem2 --report "$WORK/reports/idem2.md" --issue 1370 --state-dir "$STATE" >/dev/null 2>&1
_drive idem2 check   1370 sk-idem ""
_drive idem2 suspect 1370 sk-idem ""
assert_eq "#1370 CONTROL: a DIFFERENT verdict in the same round is appended (2)" \
    "$(_ledger_disch_count idem2)" "2"

# ═══ 7. STANDING SELECTION: ATTRIBUTABLE BEATS RECENT WHEN NOTHING ELSE DIFFERS
#        (your-org/nexus-code#1370 ask 3) ═══════════════════════════════════
#
# The writer above refuses the duplicate row from now on; ledgers written
# BEFORE it still carry them, and `retire-preflight` reads `standing_*` from
# this renderer. Planted in the exact `.warm.ledger` shape.
_std_sha=$(printf 'warm bytes' | sha256sum | awk '{print $1}')
printf 'armed\t%s\t2026-09-02T16:15:44\t1306\t/r/warm.md\n' "$_std_sha" > "$PEND/.stdwarm.ledger"
printf 'discharged\t%s\t2026-09-02T16:59:12\tcheck\t1306\twarmsk\tattributed\n' "$_std_sha" >> "$PEND/.stdwarm.ledger"
printf 'discharged\t-\t2026-09-02T17:07:54\tcheck\t1306\twarmsk\tno-open-arm\n' >> "$PEND/.stdwarm.ledger"
printf 'discharged\t-\t2026-09-02T17:08:18\tcheck\t1306\twarmsk\tno-open-arm\n' >> "$PEND/.stdwarm.ledger"
_ev_std=$(_ev stdwarm)
assert_eq "#1370 the standing row is the ATTRIBUTED one, not the later sha=- re-record" \
    "$(_field "$_ev_std" standing_detail)" "attributed"
assert_eq "#1370 …at the attributed row's timestamp" \
    "$(_field "$_ev_std" standing_at)" "2026-09-02T16:59:12"
assert_eq "#1370 …while the re-record rows are still COUNTED (evidence class no-open-arm)" \
    "$(_field "$_ev_std" evidence)" "no-open-arm"
# CONTROL: a later sha=- row with a DIFFERENT verdict is new information and stands.
cp "$PEND/.stdwarm.ledger" "$PEND/.stdverd.ledger"
printf 'discharged\t-\t2026-09-02T18:00:00\tsuspect\t1306\twarmsk\tno-open-arm\n' >> "$PEND/.stdverd.ledger"
assert_eq "#1370 CONTROL: a later sha=- row with a DIFFERENT verdict stands" \
    "$(_field "$(_ev stdverd)" standing_verdict)" "suspect"
# CONTROL: a re-arm between the attributed row and the sha=- row makes the
# latter a new round; it stands.
printf 'armed\t%s\t2026-09-02T16:15:44\t1306\t/r/rr.md\n' "$_std_sha" > "$PEND/.stdrearm.ledger"
printf 'discharged\t%s\t2026-09-02T16:59:12\tcheck\t1306\twarmsk\tattributed\n' "$_std_sha" >> "$PEND/.stdrearm.ledger"
printf 'armed\t%s\t2026-09-02T17:00:00\t1306\t/r/rr2.md\n' "$(printf other | sha256sum | awk '{print $1}')" >> "$PEND/.stdrearm.ledger"
printf 'discharged\t-\t2026-09-02T17:07:54\tcheck\t1306\twarmsk\tambiguous-2-arms-outstanding\n' >> "$PEND/.stdrearm.ledger"
assert_eq "#1370 CONTROL: after a re-arm the later sha=- row is a new round and stands" \
    "$(_field "$(_ev stdrearm)" standing_at)" "2026-09-02T17:07:54"

# ── ASSERTION-COUNT PIN ────────────────────────────────────────────────────
# Assertions in this harness mutate GLOBALS, so an `assert_*` inside `( )` loses
# its FAIL and the suite exits 0; a missing helper is rc 127 counted by nothing.
# A green verdict is therefore not evidence the arms ran — the count is.
EXPECTED=135   # REBASE SEAM (W2-16 x #1251). Ancestor 103; dev added +1 for the
               # #1251 claude-stub positive control; this branch added +14. Either
               # side taken alone is WRONG — 117 drops dev's control, 104 drops
               # this branch's fourteen. The sum is the only resolution that
               # keeps both, and the count guard below is what catches it if it
               # is not: it asserts PASS+FAIL == EXPECTED, so a mis-summed merge
               # fails LOUDLY rather than silently under-crediting the suite.
               # +1:  #1251 claude-stub positive control (CI red)
               # +7:  #1252 A narrowing by issue + 3 negative controls
               # +7:  #1302 ledger-consulted warning + rc-3 non-fatal spawn (5d/5e)
               # +42: #1156 deliverable-keyed attribution (poles A and B, 6 controls)
               # +17: #1370 idempotent discharge (+#1366 negative controls) and standing selection
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
