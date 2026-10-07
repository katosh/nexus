#!/usr/bin/env bash
# _paste_deferral.sh — COUNT and SURFACE consecutive draft deferrals per paste
# target (your-org/nexus-code#1683 F2).
#
# THE DEFECT. Since #1674 the paste primitive refuses to paste into an input box
# that already holds typed text (`occupied-before-paste`), and
# `_paste_to_target_unlocked` answers that with rc 7: nothing pasted, never
# retried, not a self-heal fault, "the body re-composes next cycle". Correct for
# ONE cycle. But nothing counted them, so a draft that STAYS — an operator who
# walked away mid-sentence, or one of our own emits stranded unsent in the box
# (#1674's stated error direction) — withheld EVERY later emit to that target,
# indefinitely, with one log line per cycle read by nobody.
#
# WHAT THIS DOES. One small state file per target under the resolved state dir
# (`$STATE_DIR/paste-deferral/<target>`: `<count>\t<first-epoch>`), bumped on
# each `occupied-before-paste`, removed on the next successful delivery. Past
# the threshold the condition is raised through the watcher's text-carrying
# operator alert (`_operator_alert`: durable record, bell, push, bot-authored
# issue — its own cadence turns a raise per cycle into one announcement and
# hourly reminders), and `clear`ed on every delivery, as its hold-down requires.
#
# THRESHOLD — BOTH conditions, each a value WE CHOSE (not measured):
#   MONITOR_PASTE_DEFERRAL_ALERT_COUNT    (3)    consecutive deferrals, so a
#       single slow cycle never alerts;
#   MONITOR_PASTE_DEFERRAL_ALERT_SECONDS  (900)  since the FIRST of them, so an
#       operator who is simply still typing is not paged: fifteen minutes of a
#       box that never cleared is a draft nobody is working on, or a stranded
#       emit of ours.
# ERROR DIRECTION, stated: only a DELIVERY resets the run. Two different drafts
# with no emit delivered between them therefore count as one run — the run is
# about emits WITHHELD, not about one draft — so this errs toward alerting, and
# can under-alert only while emits are in fact getting through.
#
# FAIL-OPEN ON TELLING: every function returns 0, and an unwritable state dir
# loses the count, never the caller's rc.

_paste_deferral_int() { local v="$1" d="$2"; [[ "$v" =~ ^[0-9]+$ ]] || v="$d"; printf '%s' "$v"; }
_paste_deferral_file() { printf '%s/paste-deferral/%s' "${STATE_DIR:-.}" "${1//[^A-Za-z0-9._-]/_}"; }
# An `_operator_alert` key is `^[a-z0-9][a-z0-9._:-]{0,63}$`: lower-case the
# target, map the rest to `-`, bound the length.
_paste_deferral_key() {
    local t; t=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-')
    printf 'paste-draft-deferred:%.40s' "${t:-unknown}"
}

# _paste_deferral_note <target> — one more `occupied-before-paste` for <target>.
# Logs the running count; raises the operator alert past the threshold.
_paste_deferral_note() {
    local target="$1" f count=0 first="" now dir key age min_n min_s
    f=$(_paste_deferral_file "$target"); dir="${f%/*}"
    now=$(date +%s)
    { IFS=$'\t' read -r count first < "$f"; } 2>/dev/null || true
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$first" =~ ^[0-9]+$ ]] || first="$now"
    count=$(( count + 1 ))
    mkdir -p "$dir" 2>/dev/null \
        && printf '%s\t%s\n' "$count" "$first" > "$f.tmp.$$" 2>/dev/null \
        && mv -f "$f.tmp.$$" "$f" 2>/dev/null
    rm -f "$f.tmp.$$" 2>/dev/null || true
    age=$(( now - first )); (( age >= 0 )) || age=0
    min_n=$(_paste_deferral_int "${MONITOR_PASTE_DEFERRAL_ALERT_COUNT:-3}" 3)
    min_s=$(_paste_deferral_int "${MONITOR_PASTE_DEFERRAL_ALERT_SECONDS:-900}" 900)
    declare -F log >/dev/null 2>&1 \
        && log "paste_to_target: '${target}' draft deferral #${count} in a row, first ${age}s ago (your-org/nexus-code#1683; alert at >= ${min_n} and >= ${min_s}s)"
    (( count >= min_n && age >= min_s )) || return 0
    key=$(_paste_deferral_key "$target")
    if declare -F _operator_alert >/dev/null 2>&1 && _operator_alert due "$key" warning; then
        _operator_alert raise "$key" warning \
            "WATCHER EMITS WITHHELD from window '${target}': its input box has held typed text for ${age}s across ${count} consecutive paste attempts, and the watcher never pastes into a draft (it would merge into it and submit it; your-org/nexus-code#1674). Either an operator draft was left unsent, or an earlier emit of ours is stranded unsent in the box. Look at the pane: send or clear the box, and the next emit goes through." \
            || true
    fi
    return 0
}

# _paste_deferral_reset <target> — a delivery to <target> succeeded: the run of
# deferrals is over. Called on EVERY delivery (a target never deferred costs one
# stat); clears the alert every time, as `_operator_alert`'s hold-down requires.
_paste_deferral_reset() {
    local target="$1" f key
    f=$(_paste_deferral_file "$target")
    [[ -e "$f" ]] && rm -f "$f" 2>/dev/null
    key=$(_paste_deferral_key "$target")
    if declare -F _operator_alert >/dev/null 2>&1 && _operator_alert standing "$key"; then
        _operator_alert clear "$key" "an emit to '${target}' was delivered again; its input box no longer withholds them" || true
    fi
    return 0
}
