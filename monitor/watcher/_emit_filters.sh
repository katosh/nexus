#!/usr/bin/env bash
# Emit filters — the per-block stream filters that make up the bulk of
# `_gh_filter_dedup_pipeline` (which stays in main.sh, composing these
# with the `_github.sh` filters). Extracted verbatim from main.sh
# (your-org/your-nexus#180 seam S2); pure code movement, no logic
# change.
#
# Functions:
#   _filter_suppression        — manual operator override
#                                (`ng suppress-emit`; PR #188)
#   _filter_processed_comments — live re-check of the
#                                processed-comments cache
#   _filter_emit_cooldown      — last-hop per-comment rate limiter
#   _emit_cooldown_flush       — per-block helper for the cooldown loop
#   _dedup_emit_lines          — cross-source id= dedup
#
# Side-effect-free: only function definitions, no top-level state.
# Caller globals (set by main.sh before the functions are CALLED —
# nothing is read at source time):
#   STATE_DIR                      monitor/.state
#   MONITOR_EMIT_COOLDOWN_SECONDS  cooldown knob (0 disables)
# Manual emit-suppression. Reads `$STATE_DIR/emit-suppression.lines`
# once into an awk hash and drops any emit block (header + body) whose
# `id=<N>` token matches a `comment:<N>` entry in the file. Operator
# writes entries via `monitor/ng suppress-emit <id>`; the file is
# append-only and persists across watcher restarts.
#
# Robustness: blank lines, leading/trailing whitespace, and lines
# starting with `#` are ignored (so an operator commenting out an entry
# or adding context with a leading hash doesn't crash the filter).
# Unknown entry prefixes (other than `comment:`) are ignored — the
# signature: form is reserved for a future extension.
#
# A missing file degrades to a passthrough — never blocks the stream.
_filter_suppression() {
    local suppress_file="${STATE_DIR}/emit-suppression.lines"
    # LC_ALL=C: byte-handling, locale-independent. Operator comment bodies
    # carry non-ASCII (σ µ → ≈ ⟂) that the snapshot byte-truncates mid-
    # character, leaving INVALID UTF-8 in the body-preview line. Under the
    # ambient en_US.utf8 locale gawk's regex decoder warns ("Invalid
    # multibyte data detected") AND the bracket-class match at the bad byte
    # is undefined — so token extraction can mis-evaluate. Same discipline
    # `_reemit.sh` already applies to its re-feed awk (see _reemit.sh ~L194).
    LC_ALL=C awk -v suppress_file="$suppress_file" '
        BEGIN {
            while ((getline line < suppress_file) > 0) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line == "" || substr(line, 1, 1) == "#") continue
                if (substr(line, 1, 8) == "comment:") {
                    id_val = substr(line, 9)
                    if (id_val != "") {
                        suppressed["id=" id_val] = 1
                    }
                }
            }
            close(suppress_file)
            header = ""; drop = 0
        }
        function emit_or_drop() {
            if (header == "") return
            if (!drop) print header
            header = ""; drop = 0
        }
        /^(issue|pr|pr_review|issue_new|mention|cross_repo)=/ {
            emit_or_drop()
            header = $0
            drop = 0
            if (match($0, /id=[^[:space:]]+/)) {
                id_token = substr($0, RSTART, RLENGTH)
                if (id_token in suppressed) drop = 1
            }
            next
        }
        /^[[:space:]]+body:/ {
            if (header != "" && !drop) {
                print header
                print $0
                header = ""
            } else if (header != "" && drop) {
                header = ""; drop = 0
            } else {
                print
            }
            next
        }
        {
            emit_or_drop()
            print
        }
        END { emit_or_drop() }
    '
}

# Live re-check of the processed-comments cache at compose_emit time.
# The v2 scheduler stages the eligibility-filtered output of
# `_snapshot_issue_comments` in `$V2_STAGE_DIR/github_poll.out` once
# per `github_poll` task fire (600s default). Between fires, the
# staged file is re-consumed by `_v2_task_compose_emit`. If the bot
# reacts EYES on a comment AFTER a github_poll fire, the staged file
# remains the pre-reaction snapshot — the comment still LOOKS
# eligible in the staged view — for up to the full 600s window.
#
# This filter reads `$STATE_DIR/processed-comments.txt` on every
# compose_emit invocation and drops any emit block whose `id=<N>` or
# `issue_new=<N>` matches a `comment:<N>` / `issue:<N>` entry in the
# file. Same line-token discipline as `_filter_suppression`, so the
# substring-safety + whitespace/`#`-tolerance behaviour is identical.
#
# A missing file degrades to a passthrough — never blocks the stream.
_filter_processed_comments() {
    local processed_file="${STATE_DIR}/processed-comments.txt"
    # LC_ALL=C — byte-safe regex/token handling on body previews that may
    # carry byte-truncated (invalid) UTF-8. See _filter_suppression above
    # and the _reemit.sh precedent.
    LC_ALL=C awk -v processed_file="$processed_file" '
        BEGIN {
            while ((getline line < processed_file) > 0) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line == "" || substr(line, 1, 1) == "#") continue
                if (substr(line, 1, 8) == "comment:") {
                    id_val = substr(line, 9)
                    if (id_val != "") {
                        suppressed["id=" id_val] = 1
                    }
                } else if (substr(line, 1, 6) == "issue:") {
                    id_val = substr(line, 7)
                    if (id_val != "") {
                        suppressed["issue_new=" id_val] = 1
                    }
                }
            }
            close(processed_file)
            header = ""; drop = 0
        }
        function emit_or_drop() {
            if (header == "") return
            if (!drop) print header
            header = ""; drop = 0
        }
        /^(issue|pr|pr_review|issue_new|mention|cross_repo)=/ {
            emit_or_drop()
            header = $0
            drop = 0
            # Cross-repo mention shapes (`mention=`/`cross_repo=`) are owned
            # end-to-end by the re-emit registry (your-org/nexus-code#360):
            # a 🚀 evicts (stop), a bare 👀 demotes to the SLOW 6h tier, and
            # `_reemit_pending` gates the cadence at the source. The shared
            # 👀-ack drop here is the IN-$REPO snapshot path s propagation-lag
            # guard — it must NOT also suppress mentions, or the slow
            # "still on track?" re-feed of a 👀'd-but-not-🚀'd mention would
            # be killed before it ever surfaces. Pass mentions through.
            if ($0 ~ /^(mention|cross_repo)=/) { next }
            if (match($0, /id=[^[:space:]]+/)) {
                id_token = substr($0, RSTART, RLENGTH)
                if (id_token in suppressed) drop = 1
            }
            # `issue_new=<N>` carries no id= token; the prefix itself
            # is the routing key.
            if (!drop && match($0, /^issue_new=[^[:space:]]+/)) {
                id_token = substr($0, RSTART, RLENGTH)
                if (id_token in suppressed) drop = 1
            }
            next
        }
        /^[[:space:]]+body:/ {
            if (header != "" && !drop) {
                print header
                print $0
                header = ""
            } else if (header != "" && drop) {
                header = ""; drop = 0
            } else {
                print
            }
            next
        }
        {
            emit_or_drop()
            print
        }
        END { emit_or_drop() }
    '
}

# Per-comment emit-rate limiter. Last hop in `_gh_filter_dedup_pipeline`
# (see header docstring). Drops a `comment:<id>` block when its most
# recent emit stamp is younger than `MONITOR_EMIT_COOLDOWN_SECONDS` AND
# the body content-hash is unchanged. Stamps `now` + body-sha into
# `$STATE_DIR/emit-history/comment-<id>.meta` (atomic .tmp+mv) for
# every block that DOES pass — so the timestamp tracks
# actually-emitted, not just considered.
#
# Body comparison uses sha256 of the staged body line (the indented
# `  body: ...` continuation as it appears in the staged stream). An
# operator-edited comment produces a different sha → bypass the
# cooldown.
#
# Two no-op cases:
#   - `MONITOR_EMIT_COOLDOWN_SECONDS` resolves to `0` or non-numeric:
#     passthrough (don't write stamps either — keeps the on-disk
#     footprint zero when operators disable the filter).
#   - Block carries no extractable `id=<N>` token: passthrough.
#
# Garbage collection happens in `prune_archive`; this function only
# writes new entries.
_filter_emit_cooldown() {
    local cooldown="${MONITOR_EMIT_COOLDOWN_SECONDS:-300}"
    if ! [[ "$cooldown" =~ ^[0-9]+$ ]]; then
        cooldown=300
    fi
    if (( cooldown == 0 )); then
        cat
        return
    fi
    local hist_dir="${STATE_DIR}/emit-history"
    mkdir -p "$hist_dir" 2>/dev/null || true
    local now
    now=$(date +%s)
    local header="" body_line=""
    local _flush_id _flush_sha _flush_meta_ts _flush_meta_sha _flush_path _flush_drop
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^(issue|pr|pr_review|issue_new|mention|cross_repo)= ]]; then
            if [[ -n "$header" ]]; then
                _emit_cooldown_flush "$hist_dir" "$now" "$cooldown" "$header" "$body_line"
                header=""; body_line=""
            fi
            header="$line"
            body_line=""
        elif [[ "$line" =~ ^[[:space:]]+body: ]]; then
            if [[ -n "$header" && -z "$body_line" ]]; then
                body_line="$line"
            else
                if [[ -n "$header" ]]; then
                    _emit_cooldown_flush "$hist_dir" "$now" "$cooldown" "$header" "$body_line"
                    header=""; body_line=""
                fi
                printf '%s\n' "$line"
            fi
        else
            if [[ -n "$header" ]]; then
                _emit_cooldown_flush "$hist_dir" "$now" "$cooldown" "$header" "$body_line"
                header=""; body_line=""
            fi
            printf '%s\n' "$line"
        fi
    done
    if [[ -n "$header" ]]; then
        _emit_cooldown_flush "$hist_dir" "$now" "$cooldown" "$header" "$body_line"
    fi
}

# Helper for `_filter_emit_cooldown`. Decides whether the (header,
# body_line) block under construction passes the cooldown gate; if it
# does, prints both lines and stamps `comment-<id>.meta` with the
# current epoch + body sha. Pulled out of the per-line loop so the
# cooldown logic is testable in isolation and so the loop body stays
# small.
_emit_cooldown_flush() {
    local hist_dir="$1" now="$2" cooldown="$3" header="$4" body_line="$5"
    local id="" sha meta_ts meta_sha drop=0 meta_path
    if [[ "$header" =~ id=([^[:space:]]+) ]]; then
        id="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$id" ]]; then
        printf '%s\n' "$header"
        [[ -n "$body_line" ]] && printf '%s\n' "$body_line"
        return
    fi
    sha=$(printf '%s' "$body_line" | sha256sum 2>/dev/null | awk '{print $1}')
    meta_path="$hist_dir/comment-$id.meta"
    meta_ts=0
    meta_sha=""
    if [[ -f "$meta_path" ]]; then
        meta_ts=$(awk -F= '/^ts=/{print $2; exit}' "$meta_path" 2>/dev/null)
        meta_sha=$(awk -F= '/^body_sha=/{sub(/^body_sha=/, ""); print; exit}' "$meta_path" 2>/dev/null)
        [[ "$meta_ts" =~ ^[0-9]+$ ]] || meta_ts=0
    fi
    if [[ -n "$sha" && "$sha" == "$meta_sha" ]] && (( now - meta_ts < cooldown )); then
        drop=1
    fi
    if (( drop == 0 )); then
        printf '%s\n' "$header"
        [[ -n "$body_line" ]] && printf '%s\n' "$body_line"
        if [[ -n "$sha" ]]; then
            printf 'ts=%s\nbody_sha=%s\n' "$now" "$sha" > "$meta_path.tmp.$$" \
                && mv "$meta_path.tmp.$$" "$meta_path" 2>/dev/null || true
        fi
    fi
}

# Body-INDEPENDENT per-comment re-emit backoff for cross-repo bot-mention
# blocks (`mention=` / `cross_repo=` shapes). Runs as the hop right before
# `_filter_emit_cooldown`. Complements — does NOT replace — that filter:
#
#   - `_filter_emit_cooldown` keys its drop on (id, body-SHA): a comment
#     whose body changed bypasses the cooldown and re-surfaces immediately.
#     That bypass is correct for in-$REPO comments (operator edits a request
#     → re-surface fresh) and stays untouched.
#   - But a cross-repo mention re-surfaces through TWO bodies for the SAME
#     id: the durable re-emit registry (`_reemit_pending`) re-feeds the body
#     captured at registration, while the deliveries drain / GraphQL backstop
#     carry the LIVE body. When the operator edits the mention, the registry's
#     stored body and the live body DIVERGE, so the two paths present two
#     different SHAs for one id within seconds — defeating the SHA cooldown
#     and double-emitting the same mention before the orchestrator can 👀-ack
#     it (your-org/nexus-code#358: id 4802521686 emitted 10:49:49 with the
#     pre-edit body and again 10:51:50 with the `@otheruser`-edited body,
#     124 s apart).
#
# This filter caps the re-emit cadence of a mention id to at most once per
# `MONITOR_REEMIT_BACKOFF_SECONDS` REGARDLESS of body content, giving the
# orchestrator time to react. It is intentionally SEPARATE from #357's
# `last_recheck=` stamp (which bounds the ack-detection recheck cadence in
# `_reemit_gc`); the two coexist — this bounds the EMIT cadence, that bounds
# the ack-RECHECK cadence. Stamp lives in its OWN dir (`reemit-backoff/`) so
# it never entangles with the emit-history SHA cooldown.
#
# In-$REPO shapes (`issue=`/`pr=`/`pr_review=`/`issue_new=`) pass through
# verbatim — `snapshot_github` + `_filter_emit_cooldown` own their cadence.
# 0 disables (passthrough, zero on-disk footprint). Default tracks
# `MONITOR_EMIT_COOLDOWN_SECONDS` so a harness/operator that disables the
# emit cooldown also disables this (keeps the documented "re-emit cadence
# reuses MONITOR_EMIT_COOLDOWN_SECONDS" contract).
_filter_reemit_backoff() {
    local backoff="${MONITOR_REEMIT_BACKOFF_SECONDS:-${MONITOR_EMIT_COOLDOWN_SECONDS:-300}}"
    if ! [[ "$backoff" =~ ^[0-9]+$ ]]; then
        backoff=300
    fi
    if (( backoff == 0 )); then
        cat
        return
    fi
    local hist_dir="${STATE_DIR}/reemit-backoff"
    mkdir -p "$hist_dir" 2>/dev/null || true
    local now
    now=$(date +%s)
    local header="" body_line=""
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^(issue|pr|pr_review|issue_new|mention|cross_repo)= ]]; then
            if [[ -n "$header" ]]; then
                _reemit_backoff_flush "$hist_dir" "$now" "$backoff" "$header" "$body_line"
                header=""; body_line=""
            fi
            header="$line"
            body_line=""
        elif [[ "$line" =~ ^[[:space:]]+body: ]]; then
            if [[ -n "$header" && -z "$body_line" ]]; then
                body_line="$line"
            else
                if [[ -n "$header" ]]; then
                    _reemit_backoff_flush "$hist_dir" "$now" "$backoff" "$header" "$body_line"
                    header=""; body_line=""
                fi
                printf '%s\n' "$line"
            fi
        else
            if [[ -n "$header" ]]; then
                _reemit_backoff_flush "$hist_dir" "$now" "$backoff" "$header" "$body_line"
                header=""; body_line=""
            fi
            printf '%s\n' "$line"
        fi
    done
    if [[ -n "$header" ]]; then
        _reemit_backoff_flush "$hist_dir" "$now" "$backoff" "$header" "$body_line"
    fi
}

# Helper for `_filter_reemit_backoff`. Gates a single (header, body_line)
# block. Non-mention shapes and id-less blocks pass through untouched. A
# `mention=`/`cross_repo=` block with an `id=<N>` is dropped when its
# dedicated `reemit-backoff/comment-<id>.ts` stamp is younger than the
# backoff window; otherwise it prints and (re)stamps `now`. The stamp tracks
# actually-emitted state (written only when the block proceeds), so the
# window measures last-emit to now — not last-considered.
_reemit_backoff_flush() {
    local hist_dir="$1" now="$2" backoff="$3" header="$4" body_line="$5"
    if [[ ! "$header" =~ ^(mention|cross_repo)= ]]; then
        printf '%s\n' "$header"
        [[ -n "$body_line" ]] && printf '%s\n' "$body_line"
        return
    fi
    local id=""
    if [[ "$header" =~ id=([^[:space:]]+) ]]; then
        id="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$id" ]]; then
        printf '%s\n' "$header"
        [[ -n "$body_line" ]] && printf '%s\n' "$body_line"
        return
    fi
    local stamp_path="$hist_dir/comment-$id.ts" last=0
    if [[ -f "$stamp_path" ]]; then
        last=$(awk 'NR==1{print; exit}' "$stamp_path" 2>/dev/null)
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
    fi
    if (( now - last < backoff )); then
        return
    fi
    printf '%s\n' "$header"
    [[ -n "$body_line" ]] && printf '%s\n' "$body_line"
    printf '%s\n' "$now" > "$stamp_path.tmp.$$" \
        && mv "$stamp_path.tmp.$$" "$stamp_path" 2>/dev/null || true
}

# Dedup adjacent emit blocks by extracting the `id=<X>` token. Each
# emit is two lines (header + body preview); we group them as a unit.
# A header line without `id=` is passed through verbatim — keeps the
# function tolerant of unknown shapes.
_dedup_emit_lines() {
    # LC_ALL=C — byte-safe. This awk's `/^[[:space:]]*body:/` test (cmd
    # line ~12) is one of the two stages that logged "Invalid multibyte
    # data detected" in the 2026-06-24 incident; byte handling makes it
    # locale-independent. See _filter_suppression / _reemit.sh.
    LC_ALL=C awk '
        # On any line containing id=, treat as a new header. The next
        # non-header line is its body preview.
        function flush() { if (header != "") { print header; if (preview != "") print preview }; header=""; preview="" }
        /id=/ {
            # Extract the id token.
            if (match($0, /id=[^ ]+/)) { id=substr($0, RSTART, RLENGTH) } else { id="" }
            if (id != "" && (id in seen)) { skip=1; flush(); next }
            else { flush(); header=$0; preview=""; if (id != "") seen[id]=1; skip=0; next }
        }
        {
            if (skip == 1) next
            if (header != "" && preview == "" && /^[[:space:]]*body:/) { preview=$0; next }
            # Other line — passthrough flush plus print as standalone.
            flush(); print
        }
        END { flush() }
    '
}
