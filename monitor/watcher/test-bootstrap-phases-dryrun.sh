#!/usr/bin/env bash
# Tier 4 — phase-step dry-run walkthrough for monitor/install-prompt.md.
#
# Walks every bash code block in the prompt (both top-level and the
# blocks indented inside numbered-list items) and asserts:
#
#   a. After substituting GitHub-template placeholders like `<ORG>`,
#      `<REPO>`, `<APP_ID>`, `<SECRET>`, etc. with safe tokens, each
#      bash block parses cleanly via `bash -n`.
#   b. Every documented phase has at least one bash block, so a
#      regression that strips a phase's example doesn't pass silently.
#   c. Phase 3's yaml block parses as YAML after the same
#      placeholder-substitution pass.
#   d. The Phase 6 lab-addons decision matrix is well-formed:
#      exactly four rows covering (your-org,HPC) ∈ {yes,no}², with
#      the expected action keyword per row.
#
# This test runs `bash -n` and (optionally) `python3 -c 'import yaml'`
# locally only — it never executes the actual commands the prompt
# instructs the bootstrap agent to run. Real execution would touch
# GitHub, openssl, smee.io, ~/.claude/, etc. — none of which is
# appropriate in unit-test scope.
#
# Run: bash monitor/watcher/test-bootstrap-phases-dryrun.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
PROMPT="$SRC_ROOT/monitor/install-prompt.md"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$(( FAIL + 1 )); }

if [[ ! -f "$PROMPT" ]]; then
    fail "install-prompt.md not found at $PROMPT"
    echo "=== summary: 0 passed, 1 failed ==="
    exit 1
fi

WORK=$(mktemp -d -t nexus-phases-dryrun-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# --- block extractor ---------------------------------------------------
#
# Walks the prompt, emitting per-block records to $WORK/blocks/.
#
# Block boundaries: opening fence matches `^(<indent>)```(bash|yaml)`,
# closing fence is the very next line matching `^<indent>```` with the
# SAME indent. Body content has the indent prefix stripped so the inner
# bash/yaml is well-formed when handed to a parser.
#
# Indent-tracking matters because the prompt nests fenced blocks inside
# numbered-list items (indent = 3 spaces), and unindented fences
# alongside top-level prose (indent = 0). Without same-indent matching,
# the closer would slip to the wrong fence pair.
mkdir -p "$WORK/blocks"

awk -v out_dir="$WORK/blocks" '
    BEGIN { in_block = 0; n = 0; cur_phase = "preamble" }
    /^## Phase [0-9]+ —/ {
        if (match($0, /^## Phase ([0-9]+) —/, m)) {
            cur_phase = "phase-" m[1]
        } else {
            # Portable fallback: parse field 3.
            cur_phase = "phase-" $3
        }
    }
    {
        if (!in_block) {
            # Match an opening fence.
            if (match($0, /^([[:space:]]*)```([a-z]+)$/, m)) {
                in_block = 1
                indent = m[1]
                lang = m[2]
                n++
                # Filename: NNN-<phase>-<lang>.txt for deterministic ordering.
                fname = sprintf("%s/%03d-%s-%s.txt", out_dir, n, cur_phase, lang)
                next
            }
        } else {
            # Match a closing fence at the same indent depth.
            if ($0 == indent "```") {
                in_block = 0
                next
            }
            # Strip the indent prefix and emit the body line.
            line = $0
            if (length(indent) > 0 && substr(line, 1, length(indent)) == indent) {
                line = substr(line, length(indent) + 1)
            }
            print line >> fname
        }
    }
' "$PROMPT" 2>"$WORK/awk.err"
awk_rc=$?

if (( awk_rc != 0 )); then
    fail "awk block extractor failed (rc=$awk_rc):"
    sed 's/^/       /' "$WORK/awk.err" >&2
fi

# --- Case A: every bash block bash -n's cleanly ------------------------

echo '=== Case A: every fenced bash block passes bash -n ==='

mapfile -t bash_files < <(find "$WORK/blocks" -type f -name '*-bash.txt' | sort)

if (( ${#bash_files[@]} == 0 )); then
    fail "no bash blocks extracted (extractor or prompt regression?)"
else
    pass "extracted ${#bash_files[@]} bash blocks across phases"

    syntax_fails=0
    for bf in "${bash_files[@]}"; do
        name=$(basename "$bf" .txt)
        sub_file="$WORK/sub-$name.sh"

        # Substitute GitHub-template placeholders + repo target stubs
        # with safe identifiers so `bash -n` doesn't trip on `<ORG>`
        # being parsed as input-redirect to file `ORG`. The substitute
        # set is intentionally narrow — any token GitHub's docs render
        # as `<placeholder>` — to keep real bash syntax errors visible.
        sed -E '
            s/<[A-Za-z][A-Za-z0-9_-]*>/PLACEHOLDER/g
            s/<n>/1/g
        ' "$bf" > "$sub_file"

        if ! bash -n "$sub_file" 2>"$WORK/bashn-$name.err"; then
            syntax_fails=$(( syntax_fails + 1 ))
            fail "$name failed bash -n:"
            sed 's/^/       /' "$WORK/bashn-$name.err" >&2
            echo "       --- substituted body ---" >&2
            sed 's/^/         /' "$sub_file" >&2
        fi
    done

    if (( syntax_fails == 0 )); then
        pass "every bash block parses cleanly under bash -n"
    fi
fi

# --- Case B: every documented phase has at least one bash block --------

echo '=== Case B: each phase has at least one bash block ==='

# Phases per the prompt: 0..7. Some phases use bash blocks
# (gh repo create, openssl, …); Phase 3 is yaml-only (it shows the
# config schema, not a shell sequence). Loose check: each phase has
# ≥1 code block of SOME language. Catches "whole example dropped"
# regressions without false-flagging the yaml-only phase.
mapfile -t phase_nums < <(
    grep -oE '^## Phase [0-9]+ —' "$PROMPT" | awk '{print $3}'
)

phases_without_blocks=()
for p in "${phase_nums[@]}"; do
    cnt=$(find "$WORK/blocks" -type f -name "*-phase-$p-*.txt" | wc -l)
    if (( cnt == 0 )); then
        phases_without_blocks+=("$p")
    fi
done

if (( ${#phases_without_blocks[@]} == 0 )); then
    pass "every phase 0..${phase_nums[-1]} has ≥1 fenced code block"
else
    fail "phases with zero fenced code blocks: ${phases_without_blocks[*]}"
fi

# --- Case C: Phase 3 yaml block parses ---------------------------------

echo '=== Case C: Phase 3 yaml config block parses cleanly ==='

mapfile -t yaml_files < <(find "$WORK/blocks" -type f -name '*-yaml.txt' | sort)

have_pyyaml=0
if command -v python3 >/dev/null 2>&1 && \
   python3 -c 'import yaml' 2>/dev/null; then
    have_pyyaml=1
fi

if (( ${#yaml_files[@]} == 0 )); then
    fail "no yaml blocks extracted (Phase 3 lost its example?)"
elif (( have_pyyaml == 0 )); then
    pass "(skipped: python3+PyYAML unavailable) — yaml blocks extracted: ${#yaml_files[@]}"
else
    yaml_fails=0
    for yf in "${yaml_files[@]}"; do
        name=$(basename "$yf" .txt)
        sub_file="$WORK/sub-$name.yaml"
        sed -E 's/<[A-Za-z][A-Za-z0-9_-]*>/placeholder/g' "$yf" > "$sub_file"

        if ! python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
' "$sub_file" 2>"$WORK/yamln-$name.err"; then
            yaml_fails=$(( yaml_fails + 1 ))
            fail "$name failed YAML parse:"
            sed 's/^/       /' "$WORK/yamln-$name.err" >&2
            echo "       --- substituted body ---" >&2
            sed 's/^/         /' "$sub_file" >&2
        fi
    done

    if (( yaml_fails == 0 )); then
        pass "every yaml block parses cleanly (count=${#yaml_files[@]})"
    fi
fi

# --- Case D: Phase 6 lab-addons matrix walkthrough --------------------
#
# The matrix table in 6.1 drives the addon offer. Assert every cell is
# present and carries the expected action keyword — this catches the
# class of bug where someone reorders the matrix or drops a row during
# a rewrite and the prompt becomes ambiguous.
#
# TWO VARIANTS, ONE ASSERTION. This suite SHIPS to the public mirror,
# where `monitor/public-mirror/overlay/install-prompt.phase6.md` has
# already replaced Phase 6 by the time the suite runs. The mirror's
# matrix is deliberately conditioned on the HPC signal ALONE (2 cols,
# 2 rows) because the fork has no lab-org gate; source's is the
# Cartesian org × HPC (3 cols, 4 rows). Pinning the source-only header
# literal made this suite fail 2 on every built tree
# (your-org/nexus-code#979 defect 1). So locate the table STRUCTURALLY
# — the first pipe-row after the `Decision matrix` lead-in, which both
# variants carry — and assert the shape that the column count declares.
# Anything that is neither shape is a FAIL, never a skip.

echo '=== Case D: Phase 6 lab-addons matrix is well-formed ==='

matrix=$(awk '
    /^Decision matrix/ { seen = 1; next }
    seen && /^\|/      { capture = 1 }
    capture && NF == 0 { exit }
    capture            { print }
' "$PROMPT")

if [[ -z "$matrix" ]]; then
    fail "Phase 6.1 decision matrix not found (no pipe-table after a 'Decision matrix' lead-in)"
else
    # Column count from the header row: `| a | b |` splits to N+2 fields.
    matrix_cols=$(head -1 <<<"$matrix" | awk -F'|' '{ print NF - 2 }')
    data_rows=$(echo "$matrix" | awk '/^\|---/ { sep=1; next } sep { print }' | wc -l)

    case "$matrix_cols" in
    3)  # source variant: (asset-repo owner) × (HPC host) × Action
        if (( data_rows == 4 )); then
            pass "matrix (2-signal variant) has exactly 4 data rows"
        else
            fail "matrix (2-signal variant) expected 4 data rows; got $data_rows"
        fi
        if grep -qE '^\| yes \| yes \|.*Offer' <<<"$matrix"; then
            pass "matrix row (org=yes, HPC=yes) → Offer"
        else
            fail "matrix row (org=yes, HPC=yes) missing 'Offer' keyword"
        fi
        if grep -qE '^\| yes \| no .*\|.*([Ss]kip install|[Hh]PC contexts)' <<<"$matrix"; then
            pass "matrix row (org=yes, HPC=no) → note / skip install"
        else
            fail "matrix row (org=yes, HPC=no) missing note/skip keyword"
        fi
        if grep -qE '^\| no  \| yes \|.*[Ss]kip silently' <<<"$matrix"; then
            pass "matrix row (org=no, HPC=yes) → Skip silently"
        else
            fail "matrix row (org=no, HPC=yes) missing 'Skip silently' keyword"
        fi
        if grep -qE '^\| no  \| no  \|.*[Ss]kip silently' <<<"$matrix"; then
            pass "matrix row (org=no, HPC=no) → Skip silently"
        else
            fail "matrix row (org=no, HPC=no) missing 'Skip silently' keyword"
        fi
        ;;
    2)  # mirror variant: (HPC host) × Action
        if (( data_rows == 2 )); then
            pass "matrix (1-signal variant) has exactly 2 data rows"
        else
            fail "matrix (1-signal variant) expected 2 data rows; got $data_rows"
        fi
        if grep -qE '^\| yes \|.*Offer' <<<"$matrix"; then
            pass "matrix row (HPC=yes) → Offer"
        else
            fail "matrix row (HPC=yes) missing 'Offer' keyword"
        fi
        if grep -qE '^\| no  \|.*([Ss]kip install|[Hh]PC contexts)' <<<"$matrix"; then
            pass "matrix row (HPC=no) → note / skip install"
        else
            fail "matrix row (HPC=no) missing note/skip keyword"
        fi
        ;;
    *)
        fail "Phase 6.1 matrix has $matrix_cols columns; expected 3 (source) or 2 (mirror overlay)"
        ;;
    esac
fi

# --- Case E: bootstrap context block names the Phase 6 signals ---------
#
# The bootstrap-install.sh HEADER block surfaces the lab-context
# signals Phase 6 decides on. If the prompt names a signal the
# bootstrap doesn't emit, the agent can't make the documented
# decision. Tie the loop with a name-match assertion.
#
# DERIVED, NOT PINNED. The labels used to be a hardcoded list, which
# made this the second half of the same drift: the mirror overlay
# renames what Phase 6 calls its signals, and bootstrap-install.sh is
# source-only — it cannot be overlaid to match. Derive the labels from
# whichever Phase 6 is actually installed and require the EMITTER to
# carry each one; that is the direction the coupling really runs.
#
# The comparison strips angle brackets from both sides. scrub.pl is
# mode-dependent — `.md` gets the angle replacement and `.sh` the bare
# one — so on a scrubbed tree the prose label and the emitted label
# differ by exactly `<`/`>` and can never match literally. No signal
# label legitimately contains an angle bracket, so the normalization
# only ever widens by that one character class.

echo '=== Case E: matrix signals match bootstrap context lines ==='

_debracket() { tr -d '<>'; }

# Phase 6's own signal bullets: ``- `LABEL` — yes/no, …`` inside the
# section, whichever variant of the section is installed.
signals=()
while IFS= read -r sig; do
    [[ -n "$sig" ]] && signals+=("$sig")
done < <(awk '
    /^## Phase 6 /  { inphase = 1; next }
    /^## Phase 7 /  { inphase = 0 }
    inphase && /^- `[^`]+` — yes\/no/ {
        s = $0
        sub(/^- `/, "", s)
        sub(/` — yes\/no.*$/, "", s)
        print s
    }
' "$PROMPT")

# ANTI-VACUITY: a derivation that returns nothing makes the loop below
# iterate zero times and the case pass having asserted nothing. That is
# the exact failure mode this repo keeps shipping, so the count is an
# assertion in its own right, not a precondition.
if (( ${#signals[@]} == 3 )); then
    pass "Phase 6 declares exactly 3 context signals (derivation is live)"
else
    fail "Phase 6 signal derivation yielded ${#signals[@]} labels, expected 3 — extraction broken or the prompt changed shape"
fi

_emitter_normalized=$(_debracket < "$SRC_ROOT/monitor/bootstrap-install.sh")
for signal in "${signals[@]}"; do
    if grep -qF -- "$(_debracket <<<"$signal")" <<<"$_emitter_normalized"; then
        pass "bootstrap-install emits context signal '$signal'"
    else
        fail "bootstrap-install does NOT emit context signal '$signal'"
    fi
done

# --- summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
