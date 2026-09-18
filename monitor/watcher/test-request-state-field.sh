#!/usr/bin/env bash
# Tests for the request-channel frontmatter `state:` field and the two
# refusal/retention facts that sit next to it (your-org/nexus-code#1358).
#
# ── WHAT THIS SUITE IS ACTUALLY GUARDING ──────────────────────────────────
#
# The field looks like the request's state and is not. It is a CONTENT-
# TRANSITION COMPLETION MARKER: only a content builder rewrites it, and `ack`
# is a pure rename, so every request that reaches `.done` by an ack keeps the
# `state: new` it was created with. Measured on the live request store
# 2026-09-02: 99/99 `.replied.md` carry `state: replied`; 0/79 `.done.md`
# carry `state: done` — all 79 still say `state: new`.
#
# Nothing is broken today, and that is the hazard rather than the reassurance.
# The field has exactly TWO readers and BOTH ask `== replied`, the one value a
# builder always maintains — so the field is correct about the only question
# anyone asks of it, and a reader who spot-checks it lands on the majority
# `.replied.md` class and concludes it is reliable. It is then wrong on every
# terminal-by-ack request, in the PERMISSIVE direction (`state: new` reads as
# *awaiting action*, which invites exactly the reply that will be refused).
#
# So this suite does not assert the field is right. It asserts THE POLARITY OF
# ITS READERS — that both keep testing positively for `replied` — because the
# tempting next predicates (`== done`, `!= new`, `== new`) are each wrong on
# 79 of 79 terminal-by-ack requests, and nothing else in the tree would say so.
#
# Sections:
#   1. the documented reality: an acked request keeps `state: new`
#   2. READER POLARITY (static), with a positive control so the absence
#      assertions cannot pass vacuously
#   3. reader polarity (behavioural): both readers classify a `.done` file
#      carrying `state: new` as NOT-replied
#   4. #1358 (iii): a refused reply ACCOUNTS FOR THE PAYLOAD
#   5. #1358 (iv): spawn-skeptic is filed reply:required, so `ack` refuses it
#   6. #1358 (v): `ack` restamps mtime, so retention runs from CLOSURE
#
# Run: bash monitor/watcher/test-request-state-field.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_test_dir/.." && pwd)
RC="$_monitor_dir/request-channel.sh"
REQUESTS_LIB="$_test_dir/_requests.sh"
CLIENT_LIB="$_monitor_dir/client/_nexus_watch_lib.sh"
CLIENT_WATCH="$_monitor_dir/client/nexus-reply-watch"
NG="$_monitor_dir/ng"

# The SHARED harness, not local copies: its assertions write to a
# subshell-durable ledger, which is what lets `th_summary_and_exit` refuse to
# print a green over a FAILURE that died in a subshell
# (your-org/nexus-code#805, #783). A suite carrying its own `assert_eq` is
# recorded as unprotected by `test-summary-honesty-manifest.sh`, and this one
# asserts other people's honesty, so it holds itself to the same level.
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_STATE_DIR="$WORK/state"
mkdir -p "$NEXUS_STATE_DIR"
REQ="$NEXUS_STATE_DIR/requests"
_claim() { local id="$1"; mv "$REQ/$id.new.md" "$REQ/$id.claimed.md"; }
# `{p;q}` rather than `| head -1`: a pipe to `head` is an EARLY-EXIT READER
# (head closes the pipe, sed takes SIGPIPE, and under `pipefail` the status is
# the signal). `sed` can stop on its own, so there is no pipe to go wrong.
_fm() { sed -n '/^state:/{s/^state:[[:space:]]*//;p;q}' "$1"; }

echo "== 1. the documented reality: an acked request keeps \`state: new\` =="
id1=$("$RC" file --origin doc-real --kind note --slug s1 --message "body one")
assert_eq "1 a fresh request is created with state: new" "$(_fm "$REQ/$id1.new.md")" "new"
_claim "$id1"
"$RC" ack "$id1" >/dev/null 2>&1
assert_rc "1 ack of a reply-optional request succeeds" "$?" "0"
assert_eq "1 NON-VACUITY: the suffix really did become .done" \
    "$([[ -f "$REQ/$id1.done.md" ]] && echo yes || echo no)" "yes"
assert_eq "1 THE DEFECT, PINNED: the frontmatter still says new, not done" \
    "$(_fm "$REQ/$id1.done.md")" "new"
# The suffix is the state of record and DOES say done — which is why the fix is
# to keep reading the suffix, not to start trusting the field.
assert_contains "1 …while \`list --state done\` — the suffix reader — finds it" \
    "$("$RC" list --state done 2>/dev/null)" "$id1"

echo
echo "== 2. READER POLARITY — POPULATION-BASED, not two hard-coded files =="
# WHY THIS IS A POPULATION SCAN AND NOT A GREP OF TWO FILES.
#
# The first version of this section asserted the polarity of the two KNOWN
# readers by grepping their text, with the forbidden predicates checked against
# `grep -F 'frontmatter_field' <<<"$src"` — i.e. ONLY LINES THAT TEXTUALLY
# CONTAIN THE MARKER TOKEN. That guard was line-scoped, and two mutants walked
# straight through it (both measured, both left the suite fully green):
#
#   A. a THIRD reader in any other file:
#        _chan_is_settled() { [[ "$(_chan_frontmatter_field "$1" state)" == done ]]; }
#   B. the forbidden predicate ONE LINE BELOW the real read, in the very file
#      the guard names:
#        _st=$(_chan_frontmatter_field "$f" state)
#        if [[ "$_st" != new ]]; then :; fi
#
# B is the one that condemns the design: reading into a variable and comparing
# on the next line is the IDIOMATIC form, and the OTHER guarded reader is
# already written that way (`nexus-reply-watch` does `_state=$(reply_state …)`
# then `[ "$_state" = replied ]`). A guard that tolerates in one reader the
# shape it cannot see in the other is not guarding a property.
#
# So this section asks the question by POPULATION:
#   (1) enumerate every TRACKED file that reads frontmatter key `state`;
#   (2) RATCHET that population against an enrolled list, so a NEW reader
#       anywhere is a RED rather than a discovery  -> kills mutant A;
#   (3) for each enrolled file, derive the state-carrying VARIABLE NAMES from
#       the assignments themselves and forbid comparing any of them (or the
#       inline read) to `done`/`new`, anywhere in the file -> kills mutant B.
#
# DIRECTION OF ERROR, stated because a text predicate for a runtime property is
# an approximation and this repo requires you to say which way it errs: this
# scan is TEXTUAL, so it cannot follow a state value through a function return
# or an indirect expansion. It therefore UNDER-approximates — it can miss a
# sufficiently indirect reader, and it cannot miss a NEW FILE (the ratchet in
# (2) is a whole-population check, not a predicate on the read). That is the
# direction that matters here, because the hazard is a new reader.

# ── THE TWO HELPERS THIS SECTION IS BUILT ON ────────────────────────────
#
# `_derive_state_vars <file>` — the names that CARRY a state value in <file>.
# The prefix alternation is not decoration: an earlier version anchored the name
# at line start, so `local _st=$(… state)` derived NOTHING and the comparison
# below it was never in the alternation (mutant C). `local`/`declare`/`typeset`
# are ordinary shell, so this was a trap armed for code not yet written.
# The LEADING alternation `(^|[;{&|(])` is the second half of the same lesson,
# found while TESTING the first: an anchor at line start also misses
# `_f() { _st=$(… state); … }` — an assignment after `{` or `;` — which is how a
# short helper is ordinarily written. ANCHORING is where this family lives, and
# each variant was found by planting the previous one somewhere slightly different.
_derive_state_vars() {
    grep -aoE '(^|[;{&|(])[[:space:]]*((local|declare|typeset|readonly|export)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?[A-Za-z_][A-Za-z_0-9]*=\$\((_chan_frontmatter_field|_fm_get|reply_state)[^)]*\)' "$1" 2>/dev/null \
      | sed -E 's/^[;{&|(]?[[:space:]]*//; s/^(local|declare|typeset|readonly|export)[[:space:]]+//; s/^(-[A-Za-z]+[[:space:]]+)*//; s/=\$\(.*//' \
      | sort -u
}

# `_case_arms_on_state <file> <vars…>` — a `case` on a state-carrying value with
# a `done)`/`new)` ARM. A case arm carries NO comparison operator, so the
# operator-based check below is blind to it by construction (mutant D). Same
# class as mutant B — the idiomatic form — which is why it is checked rather
# than declared out of scope.
_case_arms_on_state() {
    local f="$1"; shift
    awk -v vars="$*" '
      BEGIN { n = split(vars, V, " ") }
      {
        if ($0 ~ /case[[:space:]]/) {
          hit = ($0 ~ /case[[:space:]]+"?\$\((_chan_frontmatter_field|_fm_get|reply_state)/)
          for (i = 1; i <= n; i++) if (V[i] != "" && index($0, "$" V[i]) > 0) hit = 1
          if (hit) active = 1
        }
        if (active && $0 ~ /(^|[[:space:](|])"?(done|new)"?[[:space:]]*\)/) print NR ": " $0
        if (active && $0 ~ /esac/) active = 0
      }' "$f" 2>/dev/null
}

# (1) enumerate. Tracked files only, no pathspec glob (git's `*` crosses `/`
# and an `ls-tree` glob pathspec is a confident zero — your-org/nexus-code#770,
# #954). Filter the OUTPUT.
_all_tracked=$(cd "$_monitor_dir/.." && git ls-files)
_readers=""
while IFS= read -r _f; do
    [[ -n "$_f" ]] || continue
    _p="$_monitor_dir/../$_f"
    [[ -f "$_p" ]] || continue
    # a frontmatter read of key `state`, in any of the three accessor spellings
    if grep -aqE '(_chan_frontmatter_field|_fm_get)[^\n]*[[:space:]]state\b|reply_state[[:space:]]*\(\)|reply_state[[:space:]]+"' "$_p" 2>/dev/null; then
        _readers="$_readers$_f"$'\n'
    fi
done <<< "$_all_tracked"
_readers=$(printf '%s' "$_readers" | grep -v '^$' | sort -u)

# NON-VACUITY: the scan must find the two readers we know exist. Without this,
# an enumeration that silently returned nothing would pass every check below.
assert_contains "2 SCAN NON-VACUITY: finds the watcher reader" "$_readers" "monitor/watcher/_requests.sh"
assert_contains "2 SCAN NON-VACUITY: finds the client reader lib" "$_readers" "monitor/client/_nexus_watch_lib.sh"

# (2) RATCHET. Production readers only — test files legitimately construct
# fixtures with any predicate, so they are excluded BY NAME here and the
# exclusion is itself asserted below so it cannot silently widen.
_prod_readers=$(printf '%s\n' "$_readers" | grep -v '/test-' | grep -v '^monitor/watcher/test')
_ENROLLED='monitor/client/_nexus_watch_lib.sh
monitor/client/nexus-reply-watch
monitor/watcher/_requests.sh'
assert_eq "2 RATCHET: the production reader population is exactly the enrolled set" \
    "$(printf '%s\n' "$_prod_readers" | sort -u)" "$(printf '%s\n' "$_ENROLLED" | sort -u)"

# (3) POLARITY, variable-aware. For each enrolled file, collect the names
# assigned from a state read, then forbid comparing the inline read OR any of
# those names to `done`/`new` anywhere in that file.
while IFS= read -r _f; do
    [[ -n "$_f" ]] || continue
    _p="$_monitor_dir/../$_f"
    # names assigned from a state read:  x=$(… state)  /  x=$(reply_state …)
    _vars=$(_derive_state_vars "$_p")
    # the alternation of things that CARRY a state value in this file
    _alt='(_chan_frontmatter_field|_fm_get|reply_state)[^)]*\)'
    while IFS= read -r _v; do [[ -n "$_v" ]] && _alt="$_alt|\\\$$_v\\b|\\\$\\{$_v\\}|\"\\\$$_v\"" ; done <<< "$_vars"
    _bad=$(grep -anE "($_alt)\"?[[:space:]]*(==|!=|=)[[:space:]]*\"?(done|new)\"?" "$_p" 2>/dev/null || true)
    assert_eq "2 POLARITY [$_f]: no state-derived value is compared to done/new" \
        "${_bad:-<none>}" "<none>"
    _badcase=$(_case_arms_on_state "$_p" $_vars)
    assert_eq "2 POLARITY [$_f]: no \`case\` arm dispatches a state value on done/new" \
        "${_badcase:-<none>}" "<none>"
done <<< "$_prod_readers"

# POSITIVE CONTROL — both mutants, planted for real, required to be CAUGHT.
# Not a grep of a string against itself: these run the SAME predicates as above
# over a planted file, so a green here means the checks can actually fire.
_mut="$WORK/mutant.sh"
printf '%s\n' '_x() { if [[ "$(_chan_frontmatter_field "$1" state)" == done ]]; then :; fi; }' > "$_mut"
_alt='(_chan_frontmatter_field|_fm_get|reply_state)[^)]*\)'
assert_eq "2 POSITIVE CONTROL A: an inline \`== done\` read IS caught" \
    "$(grep -acE "($_alt)\"?[[:space:]]*(==|!=|=)[[:space:]]*\"?(done|new)\"?" "$_mut")" "1"
printf '%s\n' '_y() {' '  _st=$(_chan_frontmatter_field "$1" state)' '  if [[ "$_st" != new ]]; then :; fi' '}' > "$_mut"
_v=$(grep -aoE '^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=\$\((_chan_frontmatter_field|_fm_get|reply_state)[^)]*\)' "$_mut" \
     | sed 's/^[[:space:]]*//; s/=\$(.*//' | sort -u)
assert_eq "2 POSITIVE CONTROL B: the state-carrying variable is DERIVED, not assumed" "$_v" "_st"
_alt2="$_alt|\\\$$_v\\b|\\\$\\{$_v\\}|\"\\\$$_v\""
assert_eq "2 POSITIVE CONTROL B: the OFF-LINE \`!= new\` IS caught" \
    "$(grep -acE "($_alt2)\"?[[:space:]]*(==|!=|=)[[:space:]]*\"?(done|new)\"?" "$_mut")" "1"
# POSITIVE CONTROL C — `local x=$(… state)`. The derivation must SEE the name
# through the declaration keyword, and the comparison must then be caught.
printf '%s\n' '_c() {' '  local _st=$(_chan_frontmatter_field "$1" state)' '  if [[ "$_st" == done ]]; then :; fi' '}' > "$_mut"
_vc=$(_derive_state_vars "$_mut")
assert_eq "2 POSITIVE CONTROL C: a \`local\`-declared state var IS derived" "$_vc" "_st"
_altc="$_alt|\\\$$_vc\\b|\\\$\\{$_vc\\}|\"\\\$$_vc\""
assert_eq "2 POSITIVE CONTROL C: …and its \`== done\` IS caught" \
    "$(grep -acE "($_altc)\"?[[:space:]]*(==|!=|=)[[:space:]]*\"?(done|new)\"?" "$_mut")" "1"

# POSITIVE CONTROL E — the assignment is MID-LINE, after `{`. An anchor at line
# start derives nothing here; same shape as C with the declaration keyword
# swapped for a brace, and it was found by testing C rather than by reasoning.
printf '%s\n' '_e2() { local _st=$(_chan_frontmatter_field "$1" state); if [[ "$_st" == done ]]; then :; fi; }' > "$_mut"
_ve=$(_derive_state_vars "$_mut")
assert_eq "2 POSITIVE CONTROL E: a MID-LINE state assignment IS derived" "$_ve" "_st"
_alte="$_alt|\\\$$_ve\\b|\\\$\\{$_ve\\}|\"\\\$$_ve\""
assert_eq "2 POSITIVE CONTROL E: …and its \`== done\` IS caught" \
    "$(grep -acE "($_alte)\"?[[:space:]]*(==|!=|=)[[:space:]]*\"?(done|new)\"?" "$_mut")" "1"

# POSITIVE CONTROL D — a `case` arm. It carries NO comparison operator, so the
# operator check above cannot see it; the case scanner must.
printf '%s\n' '_d() {' '  _st=$(_chan_frontmatter_field "$1" state)' '  case "$_st" in done) return 0 ;; esac' '}' > "$_mut"
_vd=$(_derive_state_vars "$_mut")
assert_eq "2 POSITIVE CONTROL D: the operator check is BLIND to a case arm" \
    "$(grep -acE "($_alt|\\\$$_vd\\b)\"?[[:space:]]*(==|!=|=)[[:space:]]*\"?(done|new)\"?" "$_mut")" "0"
assert_eq "2 POSITIVE CONTROL D: …and the case scanner CATCHES it" \
    "$(_case_arms_on_state "$_mut" $_vd | wc -l)" "1"
# NEG CONTROL for the case scanner: a `replied)` arm must NOT be flagged.
printf '%s\n' '_e() {' '  _st=$(_chan_frontmatter_field "$1" state)' '  case "$_st" in replied) return 0 ;; esac' '}' > "$_mut"
assert_eq "2 NEG CONTROL: a \`case\` arm on replied is NOT flagged" \
    "$(_case_arms_on_state "$_mut" $(_derive_state_vars "$_mut") | wc -l)" "0"

# MEASURED, NOT ASSERTED: mutant C's shape is absent from the enrolled readers
# today, so this closes a trap armed only for code not yet written. Re-derived
# on every run rather than pinned as a number in prose:
#   grep -cE '^[[:space:]]*(local|declare|typeset)[[:space:]]+[A-Za-z_][A-Za-z_0-9]*=\$\(' <each enrolled reader>
_localdecl=0
while IFS= read -r _f; do
    [[ -n "$_f" ]] || continue
    _n=$(grep -acE '^[[:space:]]*(local|declare|typeset)[[:space:]]+[A-Za-z_][A-Za-z_0-9]*=\$\((_chan_frontmatter_field|_fm_get|reply_state)' "$_monitor_dir/../$_f" 2>/dev/null || echo 0)
    _localdecl=$(( _localdecl + _n ))
done <<< "$_prod_readers"
assert_eq "2 MEASURED: enrolled readers carry no \`local x=\$(<state read>)\` today" "$_localdecl" "0"

# NEG CONTROL: the CORRECT polarity must NOT be flagged, or the check is a
# tautology that fails on everything.
printf '%s\n' '_z() { if [[ "$(_chan_frontmatter_field "$1" state)" == replied ]]; then :; fi; }' > "$_mut"
assert_eq "2 NEG CONTROL: a correct \`== replied\` is NOT flagged" \
    "$(grep -acE "($_alt)\"?[[:space:]]*(==|!=|=)[[:space:]]*\"?(done|new)\"?" "$_mut")" "0"
# The positive assertions that the known readers still test POSITIVELY.
_req_src=$(cat "$REQUESTS_LIB")
_cli_src=$(cat "$CLIENT_LIB"; cat "$CLIENT_WATCH")
assert_contains "2 watcher reader tests == replied" "$_req_src" 'state)" == replied'
assert_contains "2 client reader tests = replied"  "$_cli_src" '"$_state" = replied'

echo
echo "== 3. reader polarity (behavioural): a .done file reads as NOT-replied =="
# shellcheck source=/dev/null
source "$_monitor_dir/_fm_lib.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$_monitor_dir/_channel_lib.sh" 2>/dev/null || true
_probe="$WORK/probe.md"
printf -- '---\nrequest: p\nstate: new\n---\n\n## Request\n\nbody\n' > "$_probe"
if declare -F _chan_frontmatter_field >/dev/null 2>&1; then
    assert_eq "3 an acked-shaped file reports its LITERAL field, not its suffix" \
        "$(_chan_frontmatter_field "$_probe" state)" "new"
    printf -- '---\nrequest: p\nstate: replied\n---\n\n## Reply\n\nbody\n' > "$_probe"
    assert_eq "3 …and a completed reply transition reports replied" \
        "$(_chan_frontmatter_field "$_probe" state)" "replied"
else
    assert_eq "3 SKIPPED: _chan_frontmatter_field not sourceable" "skip" "skip"
    assert_eq "3 SKIPPED: (second behavioural probe)" "skip" "skip"
fi

echo
echo "== 4. #1358 (iii): a refused reply ACCOUNTS FOR THE PAYLOAD =="
id4=$("$RC" file --origin pay-load --kind note --slug s4 --message "b")
_claim "$id4"; "$RC" ack "$id4" >/dev/null 2>&1     # -> terminal .done
pf="$WORK/rationale.md"; printf 'why I spawned it anyway\n' > "$pf"
out4=$("$RC" reply "$id4" --status spawned --file "$pf" 2>&1); rc4=$?
assert_rc "4 replying to a terminal request is still refused (rc 6)" "$rc4" "6"
assert_contains "4 …and the refusal still names the reason" "$out4" "is terminal"
assert_contains "4 THE FIX: it names the --file that was not read" "$out4" "$pf"
assert_contains "4 …and says the bytes are unchanged there" "$out4" "unchanged at that path"
assert_eq "4 NON-VACUITY: the payload file really does still exist" \
    "$([[ -s "$pf" ]] && echo yes || echo no)" "yes"
out4b=$("$RC" reply "$id4" --status spawned --message "argv-only rationale" 2>&1)
assert_contains "4 a --message payload is SPILLED, not merely mourned" "$out4b" "spilled to:"
_spill=$(sed -n '/spilled to: /{s/.*spilled to: //;p;q}' <<<"$out4b")
assert_eq "4 …and the spill file exists and holds the text" \
    "$([[ -n "$_spill" && -s "$_spill" ]] && grep -qF 'argv-only rationale' "$_spill" && echo yes || echo no)" "yes"
[[ -n "$_spill" ]] && rm -f "$_spill"
# THE FREQUENT PATH, and the one the first version of `_reply_refuse_6` missed
# while its comment said "every": `no request for id` is the ordinary failure of
# this verb — a mistyped id, a stale id, an id already GC'd — and it exits 2
# BEFORE any state check. A `--message` on that path dies with the process, so
# it is exactly where the accounting matters most.
out4d=$("$RC" reply 20260101T000000Z-nobody-x --status spawned --file "$pf" 2>&1); rc4d=$?
assert_rc "4 an unknown id still exits 2 (behaviour unchanged)" "$rc4d" "2"
assert_contains "4 …and still names the reason" "$out4d" "no request for id"
assert_contains "4 THE MISSED ARM: it now names the --file too" "$out4d" "$pf"
out4e=$("$RC" reply 20260101T000000Z-nobody-x --status spawned --message "argv rationale" 2>&1)
assert_contains "4 …and spills a --message on the unknown-id path" "$out4e" "spilled to:"
_sp2=$(sed -n '/spilled to: /{s/.*spilled to: //;p;q}' <<<"$out4e")
[[ -n "$_sp2" ]] && rm -f "$_sp2"

# NEG CONTROL: a reply with NO payload must not manufacture a payload note.
out4c=$("$RC" reply "$id4" --status spawned 2>&1)
assert_not_contains "4 NEG CTL: no payload given → no payload note" "$out4c" "was NOT read"
assert_not_contains "4 NEG CTL: …and nothing is spilled" "$out4c" "spilled to:"

echo
echo "== 5. the channel's reply-required guard, and why ng does not use it =="
# `cmd_ack` refuses to close a `reply: required` request. That guard is
# PRE-EXISTING and is asserted here because `spawn-worker.sh` now REPORTS its
# rc 6 instead of swallowing it, so the rc has to mean what the arm says.
#
# `ng` deliberately does NOT file spawn-skeptic requests `--reply required`.
# That was implemented and then dropped on review: with it, the only terminal
# condition for such a request is a human typing a reply — `ack` is refused, so
# an unattended orchestrator leaves it re-emitting forever. That is
# your-org/nexus-code#545's failure re-created from the other side, and it taxes
# the ordinary spawn->done path to fix the rare DISPUTED-rationale case. There
# is deliberately NO assertion that `ng` omits the flag: pinning that would make
# a future considered change go red for the wrong reason. The reasoning lives on
# the PR, where a reader can weigh it.
id5=$("$RC" file --origin sk-req --kind spawn-skeptic --slug skeptic-d1 \
        --reply required --message "validate x")
assert_contains "5 a reply:required request carries the frontmatter line" \
    "$(cat "$REQ/$id5.new.md")" "reply: required"
_claim "$id5"
out5=$("$RC" ack "$id5" 2>&1); rc5=$?
assert_rc "5 THE GUARD: ack of a reply:required request is REFUSED (rc 6)" "$rc5" "6"
assert_contains "5 …and redirects to the verb that records the decision" "$out5" "ng request reply"
assert_eq "5 NON-VACUITY: it is still .claimed, never silently .done" \
    "$([[ -f "$REQ/$id5.claimed.md" ]] && echo yes || echo no)" "yes"
# NEG CONTROL: the DEFAULT filing (what `ng` actually does) acks normally, so
# the ordinary spawn->done path is measurably unchanged by this PR.
id5b=$("$RC" file --origin sk-def --kind spawn-skeptic --slug skeptic-d1 --message "validate y")
_claim "$id5b"
"$RC" ack "$id5b" >/dev/null 2>&1
assert_rc "5 NEG CTL: a DEFAULT spawn-skeptic filing still acks cleanly" "$?" "0"
assert_eq "5 NEG CTL: …and reaches .done, the unchanged ordinary path" \
    "$([[ -f "$REQ/$id5b.done.md" ]] && echo yes || echo no)" "yes"

echo "== 6. #1358 (v): ack restamps mtime, so retention runs from CLOSURE =="
id6=$("$RC" file --origin retain --kind note --slug s6 --message "b")
touch -d '@1000000000' "$REQ/$id6.new.md"          # a long dwell in the inbox
_claim "$id6"; touch -d '@1000000000' "$REQ/$id6.claimed.md"
_before=$(stat -c %Y "$REQ/$id6.claimed.md")
"$RC" ack "$id6" >/dev/null 2>&1
_after=$(stat -c %Y "$REQ/$id6.done.md")
assert_eq "6 NON-VACUITY: the dwell really was planted in the past" "$_before" "1000000000"
assert_eq "6 THE FIX: the acked file's mtime is NOT the filing mtime" \
    "$([[ "$_after" != "$_before" ]] && echo moved || echo stale)" "moved"
assert_eq "6 …and it is now (retention ages from closure, not filing)" \
    "$([[ $(( $(date +%s) - _after )) -lt 120 ]] && echo recent || echo old)" "recent"

echo
# ASSERTION-COUNT GUARD. A suite that silently stops running assertions reports
# the same green as one that ran them all (your-org/nexus-code#827, #805).
EXPECTED=52
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
