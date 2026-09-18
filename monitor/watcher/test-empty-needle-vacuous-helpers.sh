#!/usr/bin/env bash
# NO LOCAL VERDICT HELPER MAY BE VACUOUS ON AN EMPTY NEEDLE.
# (your-org/nexus-code#1110 — the residual `#1092` mis-scoped.)
#
# ── THE AXIS ERROR THIS EXISTS TO CORRECT ───────────────────────────────
#
# `#1038` guarded the SHARED `assert_contains`. `#1092` guarded all 87 LOCAL
# copies of it. Both are right and both are keyed on a NAME, and `#1092`'s PR
# justified that scope with a claim that was wrong by the very axis error the
# fix was built to avoid: it classified by NAME while the vacuity lives in the
# BODY. `assert_matches`, `assert_out`, `assert_ctx` and `ck_has` share no name
# with `assert_contains`, with each other, or with anything else — so no
# name-keyed population can ever reach them, however total it is on its own key.
#
# THE HAZARD IS NOT A NAME AND NOT A SPELLING. It is a behaviour:
#
#     a helper that renders a verdict about a value it never looked at,
#     because the needle it was asked to look FOR arrived empty.
#
# `grep -qF ""` matches every line, `*""*` matches every string, and
# `[[ $x =~ "" ]]` matches every string. Three different spellings, one defect.
# So this guard PROPOSES candidates from the BODY and decides membership by
# EXECUTION. No name is consulted after enumeration — which is how it found
# `ck_has`, a fourth member `#1110` itself did not name and no `assert_*` sweep
# could have reached.
#
# ── THE CLASSIFIER: THREE CONDITIONS, AND WHY ALL THREE ARE LOAD-BEARING ─
#
# A helper H is EMPTY-NEEDLE VACUOUS at argument position i when, for some
# assignment `base` of the globals its body references:
#
#   (a) VACUITY — with argument i EMPTY, H takes its PASS arm for EVERY fill
#       of the other argument positions. Its verdict has stopped depending on
#       the value it was asked to check.
#
#   (b) POTENCY — with argument i set to a value that is absent, H can take
#       its FAIL arm in the same context. This proves position i really IS a
#       needle. Without (b) every unconditional-pass helper qualifies.
#
#   (c) THERE MUST BE A HAYSTACK — with a PRESENT needle, H's verdict must
#       DEPEND on some other slot (an argument position or a referenced
#       global), varied ONE AT A TIME.
#
# (a) alone is not the property, and getting that wrong is not hypothetical:
# an earlier draft of this file ran (a)+(b) only and flagged `assert_eq` — an
# equality, held against a constant, mimics a containment when one operand is
# empty. Varying ALL non-needle arguments TOGETHER in (a) removes that: an
# equality against a VARYING operand cannot pass for every fill; a vacuous
# containment can.
#
# (c) is what separates a vacuous containment from `assert_empty`, where an
# empty argument is exactly what is being asserted and nothing else was ever
# consulted. Without (c) this guard reported five `assert_empty` copies —
# including the shared one — as defects. Measured: 12 flagged without (c),
# 7 with it, and the five that left were all `assert_empty`. (c) is varied one
# slot at a time rather than all together because a PRECONDITION global must
# stay satisfied while the haystack global moves: `assert_ctx` is
# `[[ $RC -eq 0 && "$OUT" == *"$2"* ]]`, and coupling RC to OUT hides it.
#
# ── WHAT A GREEN HERE DOES NOT CERTIFY ──────────────────────────────────
#
# Three boundaries, each MEASURED and printed on every run rather than
# asserted, because a bound that is honest, tested and false is this repo's
# recurring failure.
#
#  * FILE SCOPE. The population is functions defined in SUITE files — a file
#    that defines an `assert_*` or sources `_test_helpers.sh`. Verdict-shaped
#    bodies exist outside that set: measured tree-wide, 789 function bodies
#    reference a verdict primitive and 437 of them are PRODUCTION functions
#    (`gh`, `cleanup`, `cmd_restart_orchestrator`, `reap_stale_builds`, …)
#    that merely use `ok`/`fail` as ordinary words. They are NOT probed, and
#    that is a deliberate refusal rather than an oversight: this guard decides
#    membership by EXECUTING the candidate, and executing arbitrary production
#    code with junk arguments is a hazard a guard must not create.
#
#  * PURITY. Within the suite files, a candidate whose body mentions any
#    command outside a default-DENY allowlist is reported UNPROBED, counted
#    and NAMED — never silently counted clean. "I could not look" and "I
#    looked and it was fine" are the two answers this repo's dominant defect
#    class depends on being confused.
#
#  * HELD-CONSTANT SLOTS. This bullet was WRONG, and it is restated on the axis
#    the MECHANISM varies on rather than the axis the search varied on:
#
#        ANY SLOT THIS PROBE HOLDS CONSTANT IS A SLOT WHOSE VACUITY IT CANNOT
#        SEE — as a needle OR as a haystack.
#
#    It used to read "positions 2, 3 and 4 are probed; a needle at position 5 or
#    beyond is out of reach". Honest, tested, and FALSE: it never mentioned
#    position 1, which was hard-wired to a constant label, so slot 1 was neither
#    probed as a needle (`for i in 2 3 4`) nor varied as a haystack
#    (`slots="2 3 4"`). TWO live helpers escaped:
#
#      test-instance-lock.sh  check_msg  needle at $1                    7 calls
#      test-gh-capable.sh     contains   needle at $2, HAYSTACK at $1   15 calls
#
#    `contains` is the one that settles the axis. Its needle sits at position
#    2 — a position the old sentence DECLARED covered — and it escaped anyway,
#    because its HAYSTACK is at position 1, so condition (c) could never see
#    the verdict move. It is not an arity gap, so "how far right the needle can
#    sit" was never the right boundary.
#
#    Every slot 1-4 is now probed as a needle AND varied as a haystack, as is
#    every global the body references. A needle at position 5+, or a haystack
#    that reaches the body by neither route (a file it reads, a command it
#    runs), remains out of reach — by that same mechanism, stated once.
#    (your-org/nexus-code#1127 skeptic.)
#
# Run: bash monitor/watcher/test-empty-needle-vacuous-helpers.sh
# Expected: ALL TESTS PASSED, exit 0.  Takes ~60 s (it executes ~450 helpers).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

# THE FIXTURE EXEMPTION IS A MARKER, NOT A FILENAME. A guard of this class
# must PLANT deliberately-vacuous helpers as its own positive controls, and
# those plants are real text in a real tracked file — so this guard finds
# them and would report its sibling as three defects. Exempting by filename
# would exempt every real helper in that file too, and would go silently
# wrong the day the file is renamed. The marker is exempted, every exemption
# is PRINTED, and the count is asserted, so an exemption added to hide a real
# defect arrives as a failing assertion rather than as a smaller number.
ENV_FIXTURE_MARKER='vacuity-fixture: deliberately unguarded'

# ── enumeration, in four declared stages ────────────────────────────────
# 1. SUITE FILES — the file-level scope boundary.
# `grep` exits 1 for NO MATCH and >1 for a real error, and this file runs under
# `pipefail` — so a bare `git grep` in a pipeline turns "nothing matched" into a
# failed enumeration, which `gp_render` correctly refuses to report. Tolerate 1,
# propagate anything above it: an enumerator that cannot say why it is empty is
# the silent zero this guard exists to forbid.
_env_grep_l() {   # _env_grep_l <regex>
    local rc
    git -C "$REPO_ROOT" grep -lE "$1" -- . 2>/dev/null
    rc=$?
    [ "$rc" -le 1 ] || return "$rc"
    return 0
}
_env_suite_files() {
    local are='^[[:space:]]*(function[[:space:]]+assert_[A-Za-z0-9_]*([[:space:]]|\{|\(|$)|assert_[A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\))'
    # ANY MENTION of the shared helpers, not a source-line SHAPE. The strict
    # form required the path to be one unbroken non-space run after `.`, so
    # `. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"` — the most ordinary
    # spelling there is — did not match. A planted untracked suite in exactly
    # that shape SURVIVED this guard (mutant M4), which is why the key is a
    # mention and the primitives are a second, independent way in.
    local src='_test_helpers\.sh'
    local prim='^[[:space:]]*(function[[:space:]]+)?(pass|fail|ok|bad)[[:space:]]*\([[:space:]]*\)'
    {
        _env_grep_l "$are"
        _env_grep_l "$src"
        _env_grep_l "$prim"
        # Tracked AND untracked: a population computed from the index cannot
        # see the file you just wrote (your-org/nexus-code#1054).
        #
        # The untracked half goes through the SHARED helper
        # (your-org/nexus-code#1197). It used to be a hand-rolled per-file
        # `grep -qE` loop, byte-identical to the one in
        # test-empty-needle-local-copies.sh — one process per untracked file,
        # reading every byte. On the operator nexus that read 42 GB, blew
        # guards-for-diff's 180 s probe budget, and took the whole index down to
        # exit 2 REFUSED. Two copies of a cost bug is one copy that stays broken
        # after the other is fixed.
        gp_untracked_matching "$REPO_ROOT" "$are|$src|$prim"
        true
    } | sort -u
}

. "$_test_dir/../_guard_population.sh"
gp_population() { ( cd "$REPO_ROOT" && _env_suite_files ); }
gp_handle "$@"

# 2. FUNCTION DEFINITIONS inside them, all three of bash's productions.
#    Emits  <file>\t<name>\t<start>\t<end>.
_ENV_AWK='
!inbody {
  name = ""
  if (match($0, /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*([ \t]|\(|\{|$)/)) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^[ \t]*function[ \t]+/, "", s); sub(/[ \t({]$/, "", s); name = s
  } else if (match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\([ \t]*\)/)) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^[ \t]*/, "", s); sub(/[ \t]*\([ \t]*\)$/, "", s); name = s
  }
  if (name != "") {
      start = FNR
      if ($0 ~ /\}/) { print FILENAME "\t" name "\t" start "\t" start; next }
      inbody = 1; curname = name; next
  }
  next
}
inbody && /^\}[ \t]*$/ { print FILENAME "\t" curname "\t" start "\t" FNR; inbody = 0; next }
'
_env_defs() {  # <file>...
    ( cd "$REPO_ROOT" && awk "$_ENV_AWK" "$@" 2>/dev/null )
}

# 3. THE BODY KEY — does this function render a verdict? This is the stage
#    that replaces `#1092`'s name key, and it is the whole point of the file.
_ENV_VERDICT_RE='(^|[^A-Za-z0-9_])(pass|fail|ok|bad|_th_pass|_th_fail)([[:space:]]|"|'"'"'|\$|;|$)|(PASS|FAIL)\+?='
# 4. THE PURITY GATE — default-DENY. Anything not obviously read-only is
#    UNPROBED and named, never silently clean.
_ENV_IMPURE_RE='(^|[^A-Za-z0-9_/.-])(rm|mv|cp|mkdir|rmdir|touch|chmod|chown|ln|dd|tee|truncate|install|git|gh|tmux|kill|pkill|killall|curl|wget|ssh|scp|nc|python|python3|perl|ruby|node|make|sbatch|srun|docker|apptainer|sudo|su|eval|source|exec|trap|mktemp|sleep|timeout|nohup|setsid|bash|sh|zsh|env|xargs|find|systemctl|crontab|jq|yq)([^A-Za-z0-9_-]|$)'

# ── the prober ──────────────────────────────────────────────────────────
# Runs the extracted definition in a clean `bash --noprofile --norc` with the
# arm-reporting primitives the suites are known to use, and answers with the
# three conditions above. Prints `VACUOUS <pos> <base>`, `CLEAN`, or `UNDECIDED`.
# Ask the PARSER whether an extraction really is a definition of that name.
# Without this the line-start recognizer proposes Python and shell text that
# merely LOOKS like a definition — `self.end_headers`, `c.close`, `up.release`
# were all proposed at 7c4ddbb from inside heredocs. A regex may over-propose
# freely; it may not have the last word on membership.
env_defines() {   # env_defines <definition> <name> -> prints the name, or nothing
    bash --noprofile --norc -c '
        eval "$1" 2>/dev/null || exit 0
        declare -F "$2" >/dev/null 2>&1 && printf %s "$2"
    ' _ "$1" "$2" 2>/dev/null
}

# EVERY PROBE RUNS IN A THROWAWAY CWD, and this is not hygiene — it is the
# purity gate's blind spot, found by running this guard and reading `git
# status`. The gate is a default-deny allowlist over COMMAND WORDS, and a
# shell REDIRECTION is not a command word: a probed helper doing `> "$2"`
# creates a file named by whatever the probe passed. At 7c4ddbb the first run
# left `0`, `zzz` and `alpha beta gamma` in the repository root. A guard that
# writes into the tree it is auditing is a guard that can change its own
# verdict, so the cwd is moved rather than the allowlist extended — an
# allowlist cannot enumerate syntax it does not tokenise.
ENV_SANDBOX=$(mktemp -d)

env_probe() {   # env_probe <definition-text> <fn-name>
    local def="$1" fn="$2" locals globals
    locals=$(grep -oE '^[[:space:]]*(local|declare|typeset)[[:space:]]+[^;]*' <<<"$def" \
             | tr ' \t' '\n\n' | grep -oE '^[A-Za-z_][A-Za-z0-9_]*=?' | tr -d '=' | sort -u)
    globals=$(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' <<<"$def" | sed 's/^\${\?//' \
        | grep -vE '^(PATH|IFS|HOME|PWD|OLDPWD|SHELL|TMPDIR|BASH.*|FUNCNAME|LINENO|RANDOM|SECONDS|UID|EUID|PPID|HOSTNAME|LANG|LC_.*|TERM|USER|PASS|FAIL|SKIP)$' \
        | sort -u)
    [ -n "$locals" ] && globals=$(grep -vxF "$locals" <<<"$globals" || true)
    globals=$(head -6 <<<"$globals")   # bound the cost; declared, not hidden

    ( cd "$ENV_SANDBOX" && bash --noprofile --norc -c '
      DEF="$1"; FN="$2"; GLOBALS="$3"
      _run() {  # _run <a1> <a2> <a3> <a4> <slot-override-name> <slot-override-value> <base>
        (
          PASS=0; FAIL=0; ARM=""
          pass(){ ARM="${ARM}P"; }; ok(){ ARM="${ARM}P"; }; _th_pass(){ ARM="${ARM}P"; }
          fail(){ ARM="${ARM}F"; }; bad(){ ARM="${ARM}F"; }; _th_fail(){ ARM="${ARM}F"; }
          skip(){ ARM="${ARM}U"; }; _th_skip(){ ARM="${ARM}U"; }
          local g a1="$1" a2="$2" a3="$3" a4="$4" sl="$5" sv="$6" base="$7"
          while IFS= read -r g; do [ -n "$g" ] && eval "$g=\$base"; done <<<"$GLOBALS"
          case "$sl" in "") : ;; 1) a1="$sv";; 2) a2="$sv";; 3) a3="$sv";; 4) a4="$sv";; *) eval "$sl=\$sv";; esac
          eval "$DEF" 2>/dev/null || { printf U; exit 0; }
          # `</dev/null`, and it is not decoration: a probed helper that reads
          # stdin blocks forever, and a guard that hangs is worse than one that
          # fails — nothing distinguishes it from a slow suite. Measured: a
          # probe batch that should take 5 minutes ran 25, capped only by the
          # outer `timeout`.
          "$FN" "$a1" "$a2" "$a3" "$a4" </dev/null >/dev/null 2>&1
          local p=0 f=0
          [ "${PASS:-0}" -gt 0 ] 2>/dev/null && p=1
          [ "${FAIL:-0}" -gt 0 ] 2>/dev/null && f=1
          case "$ARM" in *P*) p=1 ;; esac
          case "$ARM" in *F*) f=1 ;; esac
          if   [ "$p" = 1 ] && [ "$f" = 0 ]; then printf P
          elif [ "$f" = 1 ] && [ "$p" = 0 ]; then printf F
          else printf U; fi
        )
      }
      # (a)/(b): every NON-needle argument set to <fill>, globals to <base>.
      arm() {   # arm <needlepos> <needleval> <fill> <base>
        local i="$1" nv="$2" fill="$3" base="$4" a1="$3" a2="$3" a3="$3" a4="$3"
        case "$i" in 1) a1="$nv";; 2) a2="$nv";; 3) a3="$nv";; 4) a4="$nv";; esac
        _run "$a1" "$a2" "$a3" "$a4" "" "" "$base"
      }
      # (c): everything at <base>, needle at <i>, ONE slot overridden.
      arm1() {  # arm1 <needlepos> <needleval> <base> <slot> <slotval>
        local i="$1" nv="$2" base="$3" a1="$3" a2="$3" a3="$3" a4="$3"
        case "$i" in 1) a1="$nv";; 2) a2="$nv";; 3) a3="$nv";; 4) a4="$nv";; esac
        _run "$a1" "$a2" "$a3" "$a4" "$4" "$5" "$base"
      }
      # `zzz` is the needle for (c) precisely because it IS a substring of one
      # of the fills, so a real containment can be made to pass AND to fail.
      depends() {   # depends <needlepos> <base>
        local i="$1" base="$2" s v1 v2 slots="1 2 3 4" g
        while IFS= read -r g; do [ -n "$g" ] && slots="$slots $g"; done <<<"$GLOBALS"
        for s in $slots; do
          [ "$s" = "$i" ] && continue
          v1=$(arm1 "$i" "zzz" "$base" "$s" "zzz")
          v2=$(arm1 "$i" "zzz" "$base" "$s" "alpha beta gamma")
          if { [ "$v1" = P ] && [ "$v2" = F ]; } || { [ "$v1" = F ] && [ "$v2" = P ]; }; then
            printf 1; return
          fi
        done
        printf 0
      }
      FILLS=("alpha beta gamma" "zzz" "")
      # DEFAULT-DENY: a helper whose arms never move is UNDECIDABLE, and an
      # undecidable must never be reported CLEAN. An earlier draft fell through
      # to CLEAN, which is the dominant defect class of this repo rebuilt inside
      # the guard for it: I-could-not-look printed as I-looked-and-it-was-fine.
      DECIDED=0
      for i in 1 2 3 4; do
        for base in "0" "alpha beta gamma" "zzz" ""; do
          ok_a=1
          for h in "${FILLS[@]}"; do
            r=$(arm "$i" "" "$h" "$base")
            [ "$r" = U ] || DECIDED=1
            [ "$r" = P ] || { ok_a=0; break; }
          done
          [ "$ok_a" = 1 ] || continue
          for h in "${FILLS[@]}"; do
            [ "$(arm "$i" "qqq-not-present" "$h" "$base")" = F ] || continue
            [ "$(depends "$i" "$base")" = 1 ] || continue
            printf "VACUOUS %s %s\n" "$i" "$base"; exit 0
          done
        done
      done
      [ "$DECIDED" = 1 ] && printf "CLEAN\n" || printf "UNDECIDED\n"
    ' _ "$def" "$fn" "$globals" 2>/dev/null )
}

# ═══════════════════════════════════════════════════════════════════════
echo '=== A: the classifier discriminates (positive AND negative controls) ==='
# ═══════════════════════════════════════════════════════════════════════
# A guard never seen to FAIL is not evidence. Every row here is a plant, and
# the NEGATIVE half is the one that earns its keep: each of the four `CLEAN`
# rows below was a FALSE POSITIVE of some earlier draft of this classifier.
_ctl=$(mktemp -d); trap 'rm -rf "$_ctl" "$ENV_SANDBOX"' EXIT

_env_ctl() {   # _env_ctl <label> <expected> <fn-name> <definition-text>
    local got; got=$(env_probe "$4" "$3")
    assert_eq "A: $1" "${got%% *}" "$2"
}

# --- POSITIVE: four spellings of the same defect, only two of which any
#     existing lint or name-key would find.
_env_ctl 'grep -qF "" — the #1038/#1092 spelling'      VACUOUS p \
  'p() { if grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1"; fi; }'
_env_ctl '*""* glob — the assert_out/assert_ctx spelling' VACUOUS p \
  'p() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1"; fi; }'
_env_ctl '=~ "" regex — the assert_matches spelling'   VACUOUS p \
  'p() { if [[ "$2" =~ $3 ]]; then pass "$1"; else fail "$1"; fi; }'
_env_ctl 'case arm — a spelling NO helper in the tree uses' VACUOUS p \
  'p() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" ;; esac; }'
_env_ctl 'needle at position 2, haystack in a GLOBAL'  VACUOUS p \
  'p() { if [[ "$OUT" == *"$2"* ]]; then pass "$1"; else fail "$1"; fi; }'
_env_ctl 'a numeric PRECONDITION global does not hide it' VACUOUS p \
  'p() { if [[ $RC -eq 0 && "$OUT" == *"$2"* ]]; then pass "$1"; else fail "$1"; fi; }'

# --- NEGATIVE: the four false positives that shaped the three conditions.
_env_ctl 'a GUARDED containment is clean'              CLEAN p \
  'p() { if [[ -n "$3" ]] && grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1"; fi; }'
_env_ctl 'an EQUALITY is not a containment (needs (a) to vary all args)' CLEAN p \
  'p() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1"; fi; }'
_env_ctl 'a NEGATIVE assertion passing on empty is correct'  CLEAN p \
  'p() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1"; fi; }'
_env_ctl 'assert_empty — empty IS the property (needs (c))'  CLEAN p \
  'p() { if [[ -z "$2" ]]; then pass "$1"; else fail "$1"; fi; }'
_env_ctl 'not_contains fails CLOSED on an empty needle'      CLEAN p \
  'p() { if grep -qF -- "$3" <<<"$2"; then fail "$1"; else pass "$1"; fi; }'
_env_ctl 'a helper that ALWAYS passes is not a needle (needs (b))' CLEAN p \
  'p() { pass "$1"; }'
_env_ctl 'a helper that never renders a verdict is UNDECIDED, not clean' UNDECIDED p \
  'p() { grep -qF -- "$3" <<<"$2"; }'

# --- SLOT 1 — the hole this file shipped with. Both shapes are live in the
#     tree, and neither is reachable while position 1 is a constant label.
_env_ctl 'needle at position 1 (haystack in a GLOBAL)'      VACUOUS p \
  'p() { if grep -q "$1" <<<"$MSG"; then pass "$2"; else fail "$2"; fi; }'
_env_ctl 'needle at 2 but HAYSTACK at 1 — not an arity gap' VACUOUS p \
  'p() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" ;; esac; }'
_env_ctl 'its NEGATIVE twin (haystack at 1) stays clean'    CLEAN p \
  'p() { case "$1" in *"$2"*) fail "$3" ;; *) pass "$3" ;; esac; }'

# ═══════════════════════════════════════════════════════════════════════
echo '=== B: the population is non-trivial, and its boundary is PRINTED ==='
# ═══════════════════════════════════════════════════════════════════════
_env_files=(); while IFS= read -r _f; do [ -n "$_f" ] && _env_files+=("$_f"); done < <(_env_suite_files)
_enough=0; (( ${#_env_files[@]} >= 150 )) && _enough=1
assert_eq "B: suite files found (>= 150; 383 at 7c4ddbb)" "$_enough" "1"

_ALL=0; _VERDICT=0; _UNPROBED=0; _FIXTURE=0; _UNCONFIRMED=0
_cands=(); _unprobed_list=(); _fixture_list=(); _unconfirmed_list=()
while IFS=$'\t' read -r _f _n _s _e; do
    [ -n "${_f:-}" ] || continue
    _ALL=$(( _ALL + 1 ))
    _body=$(sed -n "${_s},${_e}p" "$REPO_ROOT/$_f")
    grep -qE "$_ENV_VERDICT_RE" <<<"$_body" || continue
    _VERDICT=$(( _VERDICT + 1 ))
    if grep -qF "$ENV_FIXTURE_MARKER" <<<"$_body"; then
        _FIXTURE=$(( _FIXTURE + 1 )); _fixture_list+=("$_f:$_n"); continue
    fi
    if grep -qE "$_ENV_IMPURE_RE" <<<"$_body"; then
        _UNPROBED=$(( _UNPROBED + 1 )); _unprobed_list+=("$_f:$_n"); continue
    fi
    if [ "$(env_defines "$_body" "$_n")" != "$_n" ]; then
        _UNCONFIRMED=$(( _UNCONFIRMED + 1 )); _unconfirmed_list+=("$_f:$_n"); continue
    fi
    _cands+=("$_f"$'\t'"$_n"$'\t'"$_s"$'\t'"$_e")
done < <(_env_defs "${_env_files[@]}")

printf '  BOUNDARY (measured this run, at %s):\n' "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')" >&2
printf '    %5d function definitions in suite files\n' "$_ALL" >&2
printf '    %5d of them render a verdict (the BODY key)\n' "$_VERDICT" >&2
printf '    %5d PROBED by execution\n' "${#_cands[@]}" >&2
printf '    %5d UNPROBED — default-deny purity gate (NOT a clearance)\n' "$_UNPROBED" >&2
    printf '    %5d proposed but NOT confirmed a bash function by the parser\n' "$_UNCONFIRMED" >&2
printf '    %5d exempt as planted fixtures (by MARKER, listed below)\n' "$_FIXTURE" >&2
printf '%s\n' "${_fixture_list[@]:-}" | sed '/^$/d;s/^/      fixture-exempt: /' >&2

_enough=0; (( ${#_cands[@]} >= 300 )) && _enough=1
assert_eq "B: probeable verdict helpers found (>= 300; 600 at 7c4ddbb)" "$_enough" "1"
# The fixture exemption must not become a back door: every exemption is named
# above and the count is pinned, so one added to hide a real defect is a red.
# MEASURED, not guessed, and both numbers are pinned so the exemption cannot
# quietly widen. SIX definitions carry the marker; only FIVE reach this stage,
# because the sixth (`probe_target() { grep -qF -- "$3" <<<"$2"; }`, the
# deliberately arm-less plant) renders no verdict and so never passes the BODY
# key that precedes the exemption. The file-level count is derived from the
# SUITE FILE list rather than from `git grep`, because `git grep` reads the
# index and would not see this guard itself until it is staged (#1054).
_MARKED_FILES=0
for _f in "${_env_files[@]}"; do
    grep -qF "$ENV_FIXTURE_MARKER" "$REPO_ROOT/$_f" 2>/dev/null && _MARKED_FILES=$(( _MARKED_FILES + 1 ))
done
assert_eq "B: files carrying the fixture marker (this class owns both)" "$_MARKED_FILES" "2"
assert_eq "B: fixture-marker exemptions reaching the probe stage" "$_FIXTURE" "4"
_foreign=0
for _fx in "${_fixture_list[@]:-}"; do
    [ -n "$_fx" ] || continue
    case "${_fx%%:*}" in
        monitor/watcher/test-empty-needle-*.sh) ;;
        *) _foreign=$(( _foreign + 1 )) ;;
    esac
done
assert_eq "B: fixture exemptions outside the two guards of this class" "$_foreign" "0"

# The four known members must be IN the probed population, or C is vacuous
# about exactly the files this issue is named for.
for _known in \
    'monitor/watcher/test-tmux-window-resolver.sh	assert_matches' \
    'monitor/watcher/test-proc-exists-authorized.sh	assert_out' \
    'monitor/watcher/test-bash-footgun-guard.sh	assert_ctx' \
    'monitor/watcher/test-fork-headroom-guard.sh	ck_has' ; do
    _in=0
    for _c in "${_cands[@]}"; do [ "${_c%$'\t'*$'\t'*}" = "$_known" ] && _in=1; done
    assert_eq "B: ${_known##*	} is in the probed population" "$_in" "1"
done

# ═══════════════════════════════════════════════════════════════════════
echo '=== C: NO probeable verdict helper is vacuous on an empty needle ==='
# ═══════════════════════════════════════════════════════════════════════
_vac=(); _undec=()
for _c in "${_cands[@]}"; do
    IFS=$'\t' read -r _f _n _s _e <<<"$_c"
    _d=$(sed -n "${_s},${_e}p" "$REPO_ROOT/$_f")
    _v=$(env_probe "$_d" "$_n")
    case "${_v%% *}" in
        VACUOUS)   _vac+=("$_f:$_n  [needle at \$${_v#* }]") ;;
        UNDECIDED) _undec+=("$_f:$_n") ;;
    esac
done
printf '%s\n' "${_vac[@]:-}"   | sed '/^$/d;s/^/    VACUOUS on an empty needle: /' >&2
printf '%s\n' "${_undec[@]:-}" | sed '/^$/d;s/^/    UNDECIDED (arms indistinguishable, default-deny): /' >&2
assert_eq "C: verdict helpers vacuous on an empty needle" "${#_vac[@]}" "0"

printf '%s\n' "${_unprobed_list[@]:-}" | sed '/^$/d;s/^/    unprobed: /' >&2
printf '%s\n' "${_unconfirmed_list[@]:-}" | sed '/^$/d;s/^/    proposed but NOT parser-confirmed: /' >&2
# The ONLY default-deny bucket that used to be silent: incremented, appended to
# a list, and then neither printed nor asserted (your-org/nexus-code#1127
# skeptic). It is 0 today, so it hid nothing — but the day it is non-zero
# nobody would see it, and this file's own header promises every exclusion is
# "counted and NAMED — never silently counted clean".
assert_eq "C: candidates the parser would not confirm as a definition" "$_UNCONFIRMED" "0"

# SELF-CHECK: the rule this guard enforces, applied to this guard. A probe
# that writes into the repository is a probe that can change the population it
# is measuring, and `#1110`'s own brief says to grep your new code for a fresh
# instance of the class you are closing. This is that check, executed.
# TEST THE PRODUCER'S RC. This was a `git status … | awk | grep | wc -l`
# pipeline, and a pipeline's status is its LAST command's — so if `git status`
# failed, `wc -l` printed 0 and the check PASSED on no evidence. Inside the
# check whose own comment calls it "the rule this guard enforces, applied to
# this guard" (your-org/nexus-code#1127 skeptic residual 3).
_stray_raw=$(cd "$REPO_ROOT" && git status --porcelain --untracked-files=all 2>/dev/null); _stray_rc=$?
if [ "$_stray_rc" != 0 ]; then
    _stray="git-status-FAILED-rc$_stray_rc"     # never a number: the comparison fails LOUD
else
    _stray=$(printf '%s\n' "$_stray_raw" \
             | awk '/^\?\?/ {print substr($0,4)}' \
             | grep -Ex '0|zzz|alpha beta gamma|probe-label|qqq-not-present' | wc -l | tr -d ' ')
fi
assert_eq "C: this guard left no probe artefacts in the tree it audits" "$_stray" "0"

# The count is DERIVED, because the population grows and a literal here would
# have to be edited on every added suite — which is how a count guard becomes
# noise and then gets deleted.
EXPECTED=$(( 16 + 1 + 1 + 3 + 4 + 1 + 2 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
