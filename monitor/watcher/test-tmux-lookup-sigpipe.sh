#!/usr/bin/env bash
# test-tmux-lookup-sigpipe.sh — tmux window/pane existence lookups must not be
# written as `tmux … | grep -q` (your-org/nexus-code#622).
#
# THE DEFECT. `grep -q` exits the instant it matches, without draining. `tmux`
# then takes EPIPE, and under `set -o pipefail` that becomes the PIPELINE's
# status — so the lookup reports **"the window does not exist" at the exact
# moment the window does exist**. Eighteen production sites carried this shape:
# the watcher's respawn/unstick machinery, the launcher, spawn-worker, svc,
# paste-followup, cc-auto-update, bootstrap and entry.
#
# WHY THIS IS THE SEVERE HALF OF THE CLASS. The sibling defect that #616 fixed
# (`printf`/`echo` piped into `grep -q`, in test assertions) fails LOUD: a red
# self-announcing, someone investigates. These fail SILENT, and the consequence
# is retiring a live window or resurrecting a healthy one. `_unstick.sh` is the
# sharpest illustration — a spurious 141 made it log
# `reason=window-missing` and skip the heads-up for a window that was there.
#
# WHY THE HELPERS WERE MISSED AT FIRST, since it generalises. The initial
# enumeration filtered on "files that contain `pipefail`". That is a PROXY. The
# property is "code that EXECUTES under `pipefail`", and `main.sh` sets it at
# line 243 then sources `_respawn.sh`, `_unstick.sh` and `_cc_auto_update.sh`,
# none of which set their own options. Six of the eighteen sites — including
# all three of the highest-consequence respawn ones — live in those helpers.
# Case 3 below pins that inheritance so the reasoning cannot rot.
#
# THE "OUTPUT IS SMALL" DEFENCE IS WRONG, and it is the tempting one here since
# tmux prints a short list. The race is SCHEDULING, not buffer occupancy:
# `grep -qxF` matches an early window name and exits while tmux is still
# mid-write. #598 fired at ~90 bytes. Size never made anything safe.
#
# COVERAGE BOUNDARY. This file covers the `tmux`-producer half of #622 — every
# `tmux`/`$TMUX_CMD`/`harness_tmux` window-or-pane lookup piped into `grep -q`
# under monitor/ — and asserts both that the rewrite is behaviour-preserving
# and that no such pipe survives. It does NOT cover the other producers still
# open on #622 (`tr`, `ls`, `locale`, `ss`, `sed`, `cat`, `python`), which are
# almost entirely in `test-*.sh` and are excluded because they are unconverted,
# NOT because they are safe.
#
# Run: bash monitor/watcher/test-tmux-lookup-sigpipe.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

# ===========================================================================
# 1. EQUIVALENCE. The rewrite must change the verdict in exactly one case —
#    the defect — and in no other.
#
#    Both forms are run against the same stubbed tmux and compared. Asserting
#    only "the new form returns 0 when the window exists" would not catch a
#    rewrite that silently changed the no-server or exact-match semantics,
#    which is what a window lookup actually depends on.
# ===========================================================================
echo "--- 1. the rewrite is behaviour-preserving except on the defect ---"

# old_form/new_form take a stub body and a target; both call `tmux`.
compare() {
    local label="$1" stub="$2" target="$3" expect="$4"
    local old new
    (
        eval "$stub"
        tmux() { _stub "$@"; }
        tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$target"
        printf 'old=%s\n' "$?"
        grep -qxF "$target" <<<"$(tmux list-windows -F '#{window_name}' 2>/dev/null)"
        printf 'new=%s\n' "$?"
    ) > "$TMPOUT" 2>/dev/null
    old=$(sed -n 's/^old=//p' "$TMPOUT")
    new=$(sed -n 's/^new=//p' "$TMPOUT")
    case "$expect" in
        same)
            if [[ "$old" == "$new" ]]; then
                ok "$label: both forms agree (rc=$new)"
            else
                bad "$label" "forms DIVERGE where they must not: old=$old new=$new"
            fi
            ;;
        fixed)
            # The defect case: the old form reports failure for a window that
            # IS present; the new form must report success.
            if [[ "$old" != "0" && "$new" == "0" ]]; then
                ok "$label: old form falsely reported absent (rc=$old), new form correct (rc=0)"
            else
                bad "$label" "expected old!=0 and new==0, got old=$old new=$new.
If old==0 this host did not reproduce the race and this case proves nothing;
do NOT read that as the pipe form being safe."
            fi
            ;;
    esac
}

TMPOUT=$(mktemp) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -f "$TMPOUT"' EXIT

compare "window present"       '_stub(){ printf "alpha\nbeta\ngamma\n"; }'  beta      same
compare "window absent"        '_stub(){ printf "alpha\nbeta\ngamma\n"; }'  delta     same
compare "no tmux server"       '_stub(){ echo "no server" >&2; return 1; }' beta      same
compare "empty output"         '_stub(){ :; }'                              beta      same
compare "single window"        '_stub(){ printf "only\n"; }'                only      same
compare "name with spaces"     '_stub(){ printf "my win\nother\n"; }'       "my win"  same
compare "name with a dot"      '_stub(){ printf "a.b\nc\n"; }'              a.b       same
compare "substring is not -x"  '_stub(){ printf "alphabet\n"; }'            alpha     same
# The decisive case, forced deterministic: match on line 1 of a list larger
# than the pipe buffer, so grep exits while the producer is still writing.
compare "match early, long list" \
        '_stub(){ printf "beta\n"; printf "w%.0s\n" {1..200000}; }' beta fixed

# ===========================================================================
# 2. NO tmux LOOKUP MAY STILL USE THE PIPE FORM.
#
#    This file carries its own guard rather than relying on the #616 sigpipe
#    lint, so the conversion is protected the moment it lands rather than when
#    a separate PR merges.
# ===========================================================================
echo "--- 2. no tmux lookup pipes into grep -q, under monitor/ ---"
TMUX_LINT_RE="(tmux|TMUX_CMD\"?|harness_tmux)[^|]*\| *grep +-[A-Za-z]*q"
# EXEMPTIONS, and the residual risk they carry. Both guard files necessarily
# CONTAIN the idiom — as executable premises, as planted controls, and in the
# messages that quote it — so each exempts the other. A grep over source text
# cannot tell a fixture from a call site.
#
# The residual risk is real and worth stating rather than discovering: a
# GENUINE piped assertion written inside either guard file would be invisible
# to BOTH. Neither file is scanned by anything. Keep real assertions in these
# two out of the piped form by hand; they are short and they are the two files
# whose readers are most likely to notice.
#
# Each exemption is asserted load-bearing below, so a rename cannot leave a
# dead entry quietly widening the scan.
TMUX_LINT_EXEMPT=(
    "monitor/watcher/$(basename "${BASH_SOURCE[0]}")"      # this file
    "monitor/watcher/test-sigpipe-assertion-lint.sh"       # the #616 lint
)
# Whole-line comments are dropped: monitor/watcher/_lib.sh documents this very
# defect family in prose ("The earlier implementation piped `tmux list-windows
# … | grep -qxF`, which masked tmux's own exit status behind grep's"), and a
# lint that flags its own documentation trains people to ignore it. A trailing
# comment on a code line is still flagged — deliberately conservative. Case 2c
# below proves the comment filter is a filter and not a hole.
_tmux_scan() {
    cd "$REPO_ROOT" && grep -rEn "$TMUX_LINT_RE" --include='*.sh' monitor/ 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}
mapfile -t hits < <(
    _tmux_scan | grep -vE "^($(IFS='|'; printf '%s' "${TMUX_LINT_EXEMPT[*]}")):" || true
)
if (( ${#hits[@]} == 0 )); then
    ok "no tmux lookup pipes into grep -q (outside ${#TMUX_LINT_EXEMPT[@]} named exemptions)"
else
    for h in "${hits[@]}"; do
        bad "tmux pipe lookup" "$h
    → rewrite as: grep -qxF \"\$name\" <<<\"\$(tmux list-windows -F '#{window_name}' 2>/dev/null)\""
    done
fi

for _ex in "${TMUX_LINT_EXEMPT[@]}"; do
    mapfile -t _ex_hits < <( _tmux_scan | grep "^$_ex:" || true )
    if (( ${#_ex_hits[@]} > 0 )); then
        ok "exemption is load-bearing: $_ex suppresses ${#_ex_hits[@]} line(s)"
    else
        bad "exemption/$_ex" "this exemption suppresses NOTHING, so it is not
excluding what it claims to. Either the file was renamed or removed, or it no
longer contains the idiom — drop the exemption either way."
    fi
done

echo "--- 2b. negative control: the matcher does catch a planted instance ---"
PTMP=$(mktemp -d) || exit 1
trap 'rm -f "$TMPOUT"; rm -rf "$PTMP"' EXIT
mkdir -p "$PTMP/monitor/watcher"
# Heredoc, not printf. A fixture WRITTEN with printf, whose text contains the
# idiom, is textually indistinguishable from the idiom itself — so it trips the
# #616 sigpipe lint. That is how this file first turned every unit cell red on
# your-org/nexus-code#625: the lint is a grep over source text and cannot tell
# a fixture writer from a real assertion. A quoted heredoc puts no such line in
# the source at all. Same reason the prose above avoids spelling the shape.
cat > "$PTMP/monitor/watcher/planted.sh" <<'PLANT'
#!/usr/bin/env bash
set -uo pipefail
if tmux list-windows -F '#W' 2>/dev/null | grep -qxF "$w"; then echo hit; fi
PLANT
mapfile -t planted < <(
    cd "$PTMP" && grep -rEn "$TMUX_LINT_RE" --include='*.sh' monitor/ 2>/dev/null || true
)
if (( ${#planted[@]} == 1 )) && [[ "${planted[0]}" == *"planted.sh:3:"* ]]; then
    ok "planted \`tmux … | grep -q\` caught at the expected file and line"
else
    bad "negative control" "expected 1 hit in planted.sh:3, got ${#planted[@]}: ${planted[*]:-<none>}
The matcher does not match the idiom it claims to — case 2's green is meaningless."
fi

echo "--- 2c. the comment filter drops prose but NOT a real line ---"
cat > "$PTMP/monitor/watcher/mixed.sh" <<'MIXED'
#!/usr/bin/env bash
# tmux list-windows -F '#W' | grep -qxF "$w"   <- prose, must be ignored
if tmux list-windows -F '#W' 2>/dev/null | grep -qxF "$w"; then :; fi
MIXED
rm -f "$PTMP/monitor/watcher/planted.sh"
mapfile -t mixed < <(
    cd "$PTMP" && grep -rEn "$TMUX_LINT_RE" --include='*.sh' monitor/ 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
)
if (( ${#mixed[@]} == 1 )) && [[ "${mixed[0]}" == *"mixed.sh:3:"* ]]; then
    ok "comment on line 2 ignored, code on line 3 still caught — a filter, not a hole"
else
    bad "comment filter" "expected exactly the line-3 code hit, got ${#mixed[@]}: ${mixed[*]:-<none>}
Either the filter swallows real code (a hole) or it fails to drop prose (noise)."
fi

# ===========================================================================
# 3. THE INHERITANCE PREMISE. Six of the eighteen sites were missed because
#    the enumeration filtered on "file contains pipefail" instead of "runs
#    under pipefail". Pin both halves of that: the shell behaviour, and the
#    fact that main.sh really does set it and really does source those helpers.
# ===========================================================================
echo "--- 3. sourced helpers inherit pipefail (why the first enumeration was short) ---"
HTMP=$(mktemp -d) || exit 1
trap 'rm -f "$TMPOUT"; rm -rf "$PTMP" "$HTMP"' EXIT
cat > "$HTMP/helper.sh" <<'HELPER'
helper_fn(){ producer | grep -q x; printf 'rc=%s\n' "$?"; }
HELPER
inherited=$(bash -c '
    set -uo pipefail
    producer(){ printf "x\n"; printf "y%.0s\n" {1..200000}; }
    source "'"$HTMP"'/helper.sh"
    helper_fn' 2>/dev/null | sed -n 's/^rc=//p')
if [[ -n "$inherited" && "$inherited" != "0" ]]; then
    ok "a sourced helper that sets no options runs under the caller's pipefail (rc=$inherited)"
else
    bad "inheritance premise" "expected a non-zero rc from the sourced helper, got '$inherited'.
If this host does not reproduce it, the six helper sites are still in class —
they were converted on the strength of the shell's documented behaviour."
fi

MAIN="$REPO_ROOT/monitor/watcher/main.sh"
if [[ -r "$MAIN" ]] && grep -qE '^[[:space:]]*set -[a-z]*u?o? *pipefail|^[[:space:]]*set -uo pipefail' "$MAIN"; then
    ok "main.sh sets pipefail"
else
    bad "main.sh pipefail" "main.sh no longer sets pipefail — case 3's premise has changed"
fi
missing=()
for h in _respawn.sh _unstick.sh _cc_auto_update.sh; do
    grep -qE "^[[:space:]]*(\.|source) .*${h//./\\.}" "$MAIN" || missing+=("$h")
    # MATCH THE MECHANISM, NOT THE WORD (your-org/nexus-code#1326-adjacent; the
    # substring-vs-mechanism shape #821 already records in the summary-honesty
    # classifier, where matching the WORD `EXPECTED` anywhere in a file counted
    # `EXPECTED_TARGET` and `UNEXPECTEDLY` as count guards).
    #
    # This arm protects a real premise — these three helpers set no shell
    # options, so they run under main.sh's pipefail — and the premise is worth
    # protecting. But a bare `grep -q pipefail` fires on PROSE: a comment
    # explaining why a pipeline was avoided reds the suite while the premise it
    # asserts is untouched. Measured on this tree: `_cc_auto_update.sh` carries
    # exactly one occurrence, a comment, and sourcing the file changes NO shell
    # option (pipefail off -> off, full `set +o` set byte-identical) while still
    # INHERITING a caller's pipefail. The premise held; only the probe failed.
    #
    # So: strip comments, then require an actual `set` that names pipefail.
    # This is STRICTLY MORE PRECISE, not weaker — a real `set -o pipefail`,
    # `set -uo pipefail` or `set +o pipefail` still reds, including after a
    # `;`/`&&`/`|`. Proven both ways by the planted-mutant pair below in
    # test-tmux-lookup-sigpipe-helper-opts.sh.
    # NO PIPE. `sed … | grep -q` is what a first draft of this arm used, and it
    # was DEFEATED BY THE VERY DEFECT THIS SUITE POLICES: `grep -q` closes the
    # pipe on its first match, `sed` takes EPIPE, and under this file's own
    # `pipefail` the pipeline reports 141 — so the `if` takes the FALSE branch
    # WITH THE MATCH ALREADY FOUND. Measured: rc=0 without pipefail, rc=141
    # with it, same command, same file. A planted `set -o pipefail` therefore
    # went UNDETECTED and the suite printed ALL TESTS PASSED.
    #
    # So the comment-stripping is done inside the pattern instead: `^[^#]*`
    # forbids a `#` anywhere earlier on the line, which is what makes a prose
    # mention inert without a second process to be killed.
    if grep -qE '^[[:space:]]*set[[:space:]]+[-+][A-Za-z]*[[:space:]]+pipefail|^[^#]*[;&|][[:space:]]*set[[:space:]]+[-+][A-Za-z]*[[:space:]]+pipefail' \
         "$REPO_ROOT/monitor/watcher/$h" 2>/dev/null; then
        bad "helper opts/$h" "$h now sets its own pipefail — re-check whether it still inherits"
    fi
done
if (( ${#missing[@]} == 0 )); then
    ok "main.sh sources _respawn.sh, _unstick.sh and _cc_auto_update.sh (so they inherit it)"
else
    bad "sourcing" "main.sh no longer sources: ${missing[*]} — the inheritance argument needs revisiting"
fi

# ===========================================================================
echo
if (( FAIL > 0 )); then
    printf '%d passed, %d FAILED\n' "$PASS" "$FAIL"
    exit 1
fi
printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
exit 0
