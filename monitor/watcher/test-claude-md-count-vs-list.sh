#!/usr/bin/env bash
# test-claude-md-count-vs-list.sh — every COUNT CLAUDE.md states beside an
# ENUMERATED LIST must equal the members the list carries
# (your-org/nexus-code#1464).
#
# Run:      bash monitor/watcher/test-claude-md-count-vs-list.sh
#           bash monitor/watcher/test-claude-md-count-vs-list.sh --scan [DOC]
#           (rows only, no assertions — the live population, readable)
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. `#1214` found CLAUDE.md's pane-state entry holding
# ELEVEN states while the prose beside it said twelve, and the member it
# omitted was `unknown` — the one that means "could not look at all". The
# count is what made the omission self-confirming: the document supplied a
# number, so a reader took the number instead of recounting the list. That
# entry is guarded today by `test-claude-md-pane-state-vocabulary.sh`, which
# asserts the block against `pane-state.sh --states` in both directions — ONE
# entry of the many this document carries. Every other count-beside-list
# pairing is kept honest by care, and care is what `#1214` measured failing.
#
# `test-claude-md-block-coverage.sh` DECLINED this generalisation on `#1239`'s
# own reasoning: a lint that reddened on every entry mentioning a number would
# be suppressed, then deleted, and in the meantime would read as coverage while
# providing none. That objection is right about a PROSE lint and is the design
# constraint here: this suite is keyed on the ENUMERATION, never on prose that
# mentions a number. A sentence can only enter its population by carrying a
# machine-recognisable list, and the recogniser refuses any list it cannot
# count exactly. So it is a RATCHET with a small population — measured at
# enrolment: 4 pairings on the live document, all matching — that reddens the
# first time a count and its list disagree, rather than a lint that argues.
#
# ── THE PREDICATE, stated exactly ─────────────────────────────────────────
#
# The document is read as PARAGRAPHS: consecutive non-blank lines, joined on
# single spaces, with fenced code, tables, HTML-comment markers and headings
# excluded and each bullet line starting a paragraph of its own. Backtick
# spans are masked to one placeholder each BEFORE matching, so a dot, colon
# or number inside `code` can neither end a sentence nor state a count.
#
# A COUNT PHRASE is `N NOUN`: an optional `**`, a number word two…twenty or a
# digit count 2–99, an optional `**`, one or more spaces, then a plural word
# (letters and hyphens, ending in `s`), on a word boundary both sides and
# case-insensitive. `one`, `zero`, hyphenated forms (`two-valued`) and digits
# inside larger numbers (`2026-09-01`, `150`) never match.
#
# A pairing is recognised in exactly TWO shapes:
#
#   inline   a `:` later in the SAME SENTENCE as the count phrase, followed —
#            up to the sentence end — by a list made ONLY of backtick spans
#            and separators (`,` `;` `(` `)` `**` and the words and / or / plus
#            / then / also / either / both). At least two members. Any other
#            residue means the list is not countable from its bytes, and the
#            pairing is NOT in the population.
#   bullets  the count phrase sits in the LAST sentence of a paragraph that
#            ENDS with `:` (a closing `**` allowed), and the very next thing
#            in the document is a bullet — at the same or deeper indent for a
#            prose paragraph, strictly deeper for a bullet paragraph (its
#            sibling entries are not its members). The members are the
#            consecutive bullets at that indent.
#
# Each pairing is one row: `line  shape  stated  counted  verdict  text`, and
# `stated != counted` is MISMATCH.
#
# ── ERROR DIRECTION: THIS PREDICATE UNDER-COUNTS, deliberately ─────────────
#
# A predicate over prose for a property a human reads is an approximation, and
# this one errs toward ABSENCE — a pairing it cannot count exactly is left OUT
# of the population rather than counted wrong. Measured exclusions on the
# live document at enrolment, each a real count beside a real list:
#
#   * a count phrase before a FENCED block — "Two counting forms…:" precedes
#     the four-line COUNT-PROVENANCE block, where two lines are the forms and
#     two are provenance. Which block lines are members is not decidable from
#     bytes, so no fenced-block arm exists; "TWO modes…:" before
#     DASH-PATTERN-OPTION is the same shape.
#   * a count phrase before a TABLE — "Four plants, one fixture…:" precedes a
#     four-row table with a header row.
#   * a MIXED inline list — "the carriers are **`BASHOPTS`, `SHELLOPTS`,
#     `BASH_ENV` together with its `NEXUS_PREV_BASH_ENV` chain, and invocation
#     options such as `bash -O nullglob`**": five spans, four carriers.
#   * a list stated BEFORE its count — "`wchan`, `fd/0` and an argument-less
#     `cmdline` are the three fields that settle it."
#   * a count with no colon at all — "Two things this is NOT."
#
# So a green here says: every pairing the recogniser can count agrees. It says
# nothing about the ones above, and a reader must not take it as a claim that
# CLAUDE.md carries no wrong count. The live population is PRINTED on every run
# rather than pinned, because a pinned size would go stale on the next entry
# and a floor of zero asserts nothing; what is asserted is that the scanner
# RAN (the fixture controls below) and found no mismatch.
#
# ── CONTROLS, because an absent population must never be read as clear ────
#
#   A  a planted document with ONE matching inline pairing and ONE mismatched
#      inline pairing — the scanner must report exactly two rows, one MATCH
#      and one MISMATCH, so a zero on the live document is a measured zero.
#   B  the same for the bullets shape, with soft-wrapped continuation lines.
#   C  every exclusion above, planted, beside ONE positive control — the
#      scanner must report exactly the control, so the conservative direction
#      is checked and the decoy document is never a bare zero.
#   D  the live document: scanner rc 0, every row well-formed, no MISMATCH.
#   E  the ONE entry guarded by the other mechanism still is — the pane-state
#      suite carries its `--states` comparison and its no-hand-count guard —
#      so the two mechanisms are named together and neither can vanish alone.
#
# gawk 4.1.4 and mawk 1.3.4 (CI's default awk) were measured to agree on
# every row of every control and of the live document; the program uses no
# gawk extension.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
PANE_SUITE="$_test_dir/test-claude-md-pane-state-vocabulary.sh"

# ── this suite DECLARES its own population (the --population protocol) ──────
# your-org/nexus-code#1219. CLAUDE.md is the document this suite SCANS — every
# pairing it counts lives there, and an edit to any entry can change its
# verdict. NOTE: a declaring suite needs a guard-populations.manifest row
# (test-guards-for-diff.sh §1).
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"

# ── THE SCANNER ─────────────────────────────────────────────────────────────
# POSIX awk: no match() array argument, no gensub, no IGNORECASE, no interval
# expressions — mawk 1.3.4 is what CI's ubuntu runner calls `awk`.
read -r -d '' _CVL_AWK <<'AWK' || true
function addpara(kind, ln, ind, text) { np++; PK[np]=kind; PL[np]=ln; PI[np]=ind; PT[np]=text }
function flush() {
    if (cur_kind != "") addpara(cur_kind, cur_line, cur_ind, cur_text)
    cur_kind=""; cur_text=""; cur_line=0; cur_ind=0
}
function indent_of(s) { match(s, /^[ ]*/); return RLENGTH }
function strip(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
BEGIN {
    np=0; infence=0; cur_kind=""
    nw="two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty"
    n=split(nw, W, " "); for (i=1;i<=n;i++) NUM[W[i]]=i+1
    CP="(^|[^a-z0-9*-])(\\*\\*)?(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|[2-9]|[1-9][0-9])(\\*\\*)? +[a-z][a-z-]*s([^a-z-]|$)"
    CONN["and"]=1; CONN["or"]=1; CONN["plus"]=1; CONN["then"]=1; CONN["also"]=1; CONN["either"]=1; CONN["both"]=1
}
{
    line=$0
    if (line ~ /^[[:space:]]*```/) { flush(); if (!infence) { infence=1; addpara("fence", NR, indent_of(line), "") } else infence=0; next }
    if (infence) next
    if (line ~ /^[[:space:]]*$/) { flush(); next }
    if (line ~ /^[[:space:]]*<!--/) { flush(); addpara("comment", NR, indent_of(line), ""); next }
    if (line ~ /^[[:space:]]*\|/) { flush(); if (PK[np] != "table" || PL[np] != NR-1) addpara("table", NR, indent_of(line), ""); else PL[np]=NR; next }
    if (line ~ /^#/) { flush(); addpara("heading", NR, 0, strip(line)); next }
    if (line ~ /^[[:space:]]*[-*] /) { flush(); cur_kind="bullet"; cur_line=NR; cur_ind=indent_of(line); t=strip(line); sub(/^[-*] +/, "", t); cur_text=t; next }
    if (cur_kind == "") { cur_kind="prose"; cur_line=NR; cur_ind=indent_of(line); cur_text=strip(line); next }
    cur_text = cur_text " " strip(line); next
}
function mask(s,   out, i, c, inb) {   # every backtick span -> one \001
    out=""; inb=0
    for (i=1;i<=length(s);i++) { c=substr(s,i,1)
        if (c=="`") { if (!inb) { inb=1; out=out "\001" } else inb=0; continue }
        if (!inb) out=out c }
    return out
}
function stated_of(m,   w) {   # m = the matched count phrase, boundary char included
    if (m !~ /^[*a-z0-9]/) m=substr(m,2)
    gsub(/\*/, "", m); split(m, w, " +")
    if (w[1] in NUM) return NUM[w[1]]; return w[1]+0
}
function noun_end(start, len, m) { if (substr(m, len, 1) ~ /[a-z-]/) return start+len-1; return start+len-2 }
function sent_end(t, from,   r, p) {   # index of the char BEFORE the terminator, or the end of t
    r=substr(t, from); p=match(r, /\. |\.$/); if (p==0) return length(t); return from+p-2
}
function region_count(r,   n, tk, i, cnt) {   # members of a backtick-only list, or -1 on residue
    gsub(/[,;()]/, " ", r); gsub(/\*\*/, " ", r); n=split(r, tk, " +"); cnt=0
    for (i=1;i<=n;i++) { if (tk[i]=="") continue
        if (tk[i] ~ /^\001+$/) { cnt+=length(tk[i]); continue }
        if (tk[i] in CONN) continue
        return -1 }
    return cnt
}
function emit(ln, shape, stated, counted, orig,   v) {
    v = (stated==counted) ? "MATCH" : "MISMATCH"; gsub(/\t/, " ", orig)
    printf "%d\t%s\t%d\t%d\t%s\t%s\n", ln, shape, stated, counted, v, substr(orig,1,72)
}
END {
    flush()
    for (i=1;i<=np;i++) {
        if (PK[i]!="prose" && PK[i]!="bullet") continue
        t=tolower(mask(PT[i])); pos=1
        while (match(substr(t,pos), CP)) {
            s=pos+RSTART-1; l=RLENGTH; m=substr(t,s,l)
            ns = (m ~ /^[*a-z0-9]/) ? s : s+1          # where the number itself begins
            # a `^` that was only the SUBSTRING's start is not a word boundary
            if (ns>1 && substr(t,ns-1,1) ~ /[a-z0-9*-]/) { pos=ns+1; continue }
            stated=stated_of(m); ne=noun_end(s,l,m); se=sent_end(t, ne+1)
            # shape A — inline: a colon in the same sentence, then a backtick-only list to the sentence end
            r=substr(t, ne+1, se-ne); c=index(r, ":")
            if (c>0) { cnt=region_count(substr(r, c+1))
                if (cnt>=2) { emit(PL[i], "inline", stated, cnt, PT[i]); pos=ns+1; continue } }
            # shape B — bullets: the LAST sentence, the paragraph ends with ':', bullets follow at once
            tt=t; sub(/[[:space:]]+$/, "", tt); sub(/\*\*$/, "", tt)
            if (tt ~ /:$/) { ls=1; q=tt; while ((p=index(q, ". "))>0) { ls+=p+1; q=substr(q,p+2) }
                if (ns>=ls) { j=i+1
                    # a PROSE paragraph's list may sit at its own indent; a BULLET's members must be DEEPER,
                    # or the next sibling entry would be counted as a member of this one
                    if (j<=np && PK[j]=="bullet" && (PI[j]>PI[i] || (PK[i]=="prose" && PI[j]==PI[i]))) { bi=PI[j]; cnt=0
                        while (j<=np && PK[j]=="bullet" && PI[j]==bi) { cnt++; j++ }
                        emit(PL[i], "bullets", stated, cnt, PT[i]); pos=ns+1; continue } } }
            pos=ns+1
        }
    }
}
AWK

# _cvl_scan <doc> — one TSV row per recognised pairing; rc is awk's.
_cvl_scan() { awk "$_CVL_AWK" "$1"; }
_cvl_rows() { printf '%s\n' "$1" | grep -c .; }          # a count, never a verdict

if [[ "${1:-}" == "--scan" ]]; then
    _cvl_scan "${2:-$CLAUDE_MD}"; exit $?
fi

WORK=$(mktemp -d -t nexus-cvl-XXXXXX) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

_th_count_guard() {
    local EXPECTED_ASSERTIONS=17
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total" \
              "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

TAB=$'\t'

echo '=== §0 preconditions ==='
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

echo '=== §A control: the INLINE shape — one matching pairing, one mismatched, nothing else ==='
cat > "$WORK/a.md" <<'EOF'
# Fixture A

- **A matching entry.** The guard accepts three kinds: `alpha`, `beta` and
  `gamma`. A trailing sentence that mentions no number.
- **A mismatched entry.** It declares **4** modes: `one`, `two`, `three`. More
  prose follows, and it is not part of the list.
EOF
rows=$(_cvl_scan "$WORK/a.md"); rc=$?
assert_eq "the scanner ran on fixture A (rc 0)" "$rc" "0"
assert_eq "fixture A yields exactly 2 rows — the scanner SEES the inline shape" "$(_cvl_rows "$rows")" "2"
assert_contains "the matching pairing is a MATCH row (three stated, 3 counted)" \
    "$rows" "3${TAB}inline${TAB}3${TAB}3${TAB}MATCH${TAB}**A matching entry.**"
assert_contains "the mismatched pairing is a MISMATCH row (**4** stated, 3 counted) that NAMES its entry" \
    "$rows" "5${TAB}inline${TAB}4${TAB}3${TAB}MISMATCH${TAB}**A mismatched entry.**"

echo '=== §B control: the BULLETS shape — one matching pairing, one mismatched, soft-wrapped ==='
cat > "$WORK/b.md" <<'EOF'
# Fixture B

- **An entry with two lists.** A sentence that ends elsewhere. Two detectors,
  both cheap, neither run at the
  time:
  - **Reconcile against a declared total** before publishing, which wraps
    onto a second line.
  - **Re-fetch immediately before quoting**, not once at session start.

  THREE remedies, in order:
  - the first
  - the second

  A closing paragraph, so the bullet run above is bounded by prose.
EOF
rows=$(_cvl_scan "$WORK/b.md"); rc=$?
assert_eq "the scanner ran on fixture B (rc 0)" "$rc" "0"
assert_eq "fixture B yields exactly 2 rows — the scanner SEES the bullets shape" "$(_cvl_rows "$rows")" "2"
assert_contains "the matching pairing is a MATCH row (Two stated, 2 bullets)" \
    "$rows" "3${TAB}bullets${TAB}2${TAB}2${TAB}MATCH${TAB}"
assert_contains "the mismatched pairing is a MISMATCH row (THREE stated, 2 bullets) that NAMES its paragraph" \
    "$rows" "10${TAB}bullets${TAB}3${TAB}2${TAB}MISMATCH${TAB}THREE remedies, in order:"

echo '=== §C control: every documented EXCLUSION planted beside ONE positive control ==='
cat > "$WORK/c.md" <<'EOF'
# Fixture C — decoys, each a real count beside a real list the predicate must NOT count

- **Fenced block.** Two forms, and they answer different questions:

  <!-- BEGIN DECOY -->
  ```zsh
  git ls-files                      # one
  git ls-tree -r                    # two
  git rev-parse --short "${ref}"    # three
  git rev-parse "${ref}"            # four
  ```
  <!-- END DECOY -->

  Four plants, one fixture, git 2.17.1 on this host:

  | plant | HEAD equal |
  |---|---|
  | uncommitted edit | passes |
  | committed | FIRES |

  The carriers are **`BASHOPTS`, `SHELLOPTS`, `BASH_ENV` together with its
  `NEXUS_PREV_BASH_ENV` chain, and invocation options such as `bash -O
  nullglob`** — four carriers: `BASHOPTS`, `SHELLOPTS`, `BASH_ENV` and the
  `NEXUS_PREV_BASH_ENV` chain. `wchan`, `fd/0` and an argument-less `cmdline`
  are the three fields that settle it. Two things this is NOT. Measured on
  `dev`, **471** files, of which **346** are under `monitor/watcher/`, and
  against 5 planted files:

      find … -newermt '12 hours ago'  ->  0
      find … -mmin -720               ->  5

  It has two verbs: `ng send` and `ng request reply`. A two-valued predicate
  and a 2026-09-01 date and 150 runs are not counts either.
EOF
rows=$(_cvl_scan "$WORK/c.md"); rc=$?
assert_eq "the scanner ran on fixture C (rc 0)" "$rc" "0"
assert_eq "fixture C yields exactly 1 row — every decoy is EXCLUDED and the control is not" "$(_cvl_rows "$rows")" "1"
assert_contains "…and that row is the positive control (two verbs, 2 spans, MATCH)" \
    "$rows" "inline${TAB}2${TAB}2${TAB}MATCH${TAB}"

echo '=== §D the LIVE document — population printed, mismatches asserted ==='
rows=$(_cvl_scan "$CLAUDE_MD"); rc=$?
assert_eq "the scanner ran on the live CLAUDE.md (rc 0)" "$rc" "0"
n_live=$(_cvl_rows "$rows")
n_bad=$(printf '%s\n' "$rows" | awk -F'\t' 'NF && $5=="MISMATCH"' | grep -c .)
n_malformed=$(printf '%s\n' "$rows" | awk -F'\t' 'NF && (NF!=6 || $1!~/^[0-9]+$/ || ($5!="MATCH" && $5!="MISMATCH"))' | grep -c .)
printf '  live population: %s count-beside-list pairing(s) recognised in CLAUDE.md (printed, never pinned — #1464)\n' "$n_live"
if [[ -n "$rows" ]]; then printf '%s\n' "$rows" | sed 's/^/    /'; fi
assert_eq "every live row is well-formed (6 columns, numeric line, MATCH|MISMATCH)" "$n_malformed" "0"
if (( n_bad == 0 )); then
    assert_eq "no live pairing MISMATCHES (0 of $n_live)" "$n_bad" "0"
else
    printf '  the mismatching entries, by line and leading text:\n' >&2
    printf '%s\n' "$rows" | awk -F'\t' 'NF && $5=="MISMATCH"' | sed 's/^/    /' >&2
    assert_eq "no live pairing MISMATCHES — a stated count disagrees with the list it precedes (CLAUDE.md, lines above)" "$n_bad" "0"
fi

echo '=== §E the other mechanism: the pane-state entry is still guarded against --states ==='
assert_file_exists "the pane-state vocabulary suite exists" "$PANE_SUITE"
assert_contains "…and still compares the block against \`pane-state.sh --states\` (the one entry this suite does not cover)" \
    "$(command grep -F -e '--states' "$PANE_SUITE")" '--states'

_th_count_guard
