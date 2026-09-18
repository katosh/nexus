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
#   _filter_alert_cooldown     — per-SURFACE edge damper for
#                                `watcher_alert=` blocks (#966); the
#                                only hop that can express an alert —
#                                every other one takes its DEFAULT ARM
#                                on a non-comment header, which is a
#                                permissive-default failure and NOT an
#                                id-keying one (see "WHY NOTHING DAMPED
#                                AN ALERT" below)
#   _alert_cooldown_flush      — per-block helper for the alert damper
#   _dedup_emit_lines          — cross-source id= dedup
#
# Side-effect-free: only function definitions, no top-level state.
# Caller globals (set by main.sh before the functions are CALLED —
# nothing is read at source time):
#   STATE_DIR                            monitor/.state
#   MONITOR_EMIT_COOLDOWN_SECONDS        per-comment cooldown (0 disables)
#   `MONITOR_ALERT_EMIT_COOLDOWN_SECONDS` (default 900) — per-surface alert
#                                        damper; 0 disables. Spelled on ONE
#                                        line on purpose: `test-knob-default-
#                                        agrees.sh` reads this literal and
#                                        holds it to the config-resolved value.
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
#
# ATOMIC per-id decide+stamp (your-org/nexus-code#562 skeptic finding):
# with `comment_surface` and `compose_emit` both running this filter
# from concurrent async subshells, the bare read-modify-write let both
# read a pre-cooldown meta for the SAME comment, both pass, and the
# comment double-paste. A per-id flock around the decide+stamp
# serializes them so exactly one passes. Bounded (`-w 5`) and fail-open
# (timeout or no flock(1) → the historical unlocked behaviour: worst
# case one rare duplicate emit, never a stall).
_emit_cooldown_flush() {
    local hist_dir="$1" now="$2" cooldown="$3" header="$4" body_line="$5"
    local id=""
    if [[ "$header" =~ id=([^[:space:]]+) ]]; then
        id="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$id" ]]; then
        printf '%s\n' "$header"
        [[ -n "$body_line" ]] && printf '%s\n' "$body_line"
        return
    fi
    local meta_path="$hist_dir/comment-${id//[^A-Za-z0-9._-]/_}.meta"
    if command -v flock >/dev/null 2>&1; then
        local _cf_fd
        if { exec {_cf_fd}>"$meta_path.lock"; } 2>/dev/null; then
            # Timeout falls through to an unlocked decide (fail-open).
            flock -w 5 "$_cf_fd" 2>/dev/null || true
            _emit_cooldown_flush_decide "$now" "$cooldown" "$header" "$body_line" "$meta_path"
            exec {_cf_fd}>&-
            return
        fi
    fi
    _emit_cooldown_flush_decide "$now" "$cooldown" "$header" "$body_line" "$meta_path"
}

# The unguarded decide+stamp core of `_emit_cooldown_flush` — read the
# meta, drop-or-print, stamp on pass. Callers own any locking.
_emit_cooldown_flush_decide() {
    local now="$1" cooldown="$2" header="$3" body_line="$4" meta_path="$5"
    local sha meta_ts meta_sha drop=0
    sha=$(printf '%s' "$body_line" | sha256sum 2>/dev/null | awk '{print $1}')
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
            printf 'ts=%s\nbody_sha=%s\n' "$now" "$sha" > "$meta_path.tmp.$BASHPID" \
                && mv "$meta_path.tmp.$BASHPID" "$meta_path" 2>/dev/null || true
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

# Reaction TARGET of a cross-repo mention block (your-org/nexus-code#1500).
#
# A mention block's `id=` is NOT always a comment database id, and the two
# consumers that key on it — the backoff stamp below and `_reemit.sh`'s
# two-tier reaction classifier — were both written as though it always
# were. Measured cost: a `mention=<repo> kind=issue_new n=1499 id=1499`
# block carries an ISSUE NUMBER in `id=`, so `_reemit_reaction_state` asked
# `repos/<repo>/issues/comments/1499/reactions`, got a PERMANENT 404, and
# returned "unknown" — which by contract neither evicts nor reclassifies.
# The entry could therefore never leave the FAST (5 min) tier: not by 👀,
# not by 🚀. The reactions existed; the classifier consulted an endpoint
# that cannot see them.
#
# The three id vocabularies actually in circulation:
#   * comment mentions (`issue_comment` deliveries; `src=comment` walks)
#     → `id` is a COMMENT database id, GLOBALLY unique. Reactions at
#     `repos/{r}/issues/comments/{id}/reactions`.
#   * BODY mentions — `src=body` from the mention walk, and `kind=issue_new`
#     / a PR OPEN from the deliveries path → the reaction lives on the
#     ISSUE/PR ITSELF, at `repos/{r}/issues/{n}/reactions`, keyed on `n=`
#     and NOT on `id=`. (`repos/{r}/issues/{n}` serves PRs too — a PR is an
#     issue.) For `src=body` the `id` is the issue's databaseId, which that
#     endpoint does not accept either; for `kind=issue_new` id==n only by
#     coincidence, which is precisely why the bug read as "the right id".
#   * `kind=pr_review` WITH `path=` → a PR REVIEW COMMENT, reactions at
#     `repos/{r}/pulls/comments/{id}/reactions`. WITHOUT `path=` it is a
#     TOP-LEVEL PR review, which has NO reactions endpoint at all.
#
# One derivation, two consumers, so the mapping cannot drift between them.
#
# Prints exactly one `<type>:<value>` and ALWAYS returns 0. "Unresolvable"
# is the explicit value `none:<n|0>` rather than a bare non-zero: a caller
# that ignores rc still receives a value it has to handle, and `none:` is a
# fail-CLOSED token for which no endpoint is ever guessed.
#
# ARM ORDER (your-org/nexus-code#1121). The permissive `comment:` arm is
# LAST, and every earlier arm accepts only inputs no later arm wants:
#   - `pr_review` is never a body mention (the mention walk emits only
#     `issue`/`pr`; deliveries emits `pr_review` only for the two review
#     events), so arm 1 shadows nothing beneath it.
#   - a `src=body` / `issue_new` id is by definition not a comment id, so
#     arm 2 shadows nothing beneath it.
# Any NEW specific shape goes ABOVE the `comment:` arm, never below it.
_mention_target_key() {
    local header="$1"
    local kind="" n="" id="" src="" haspath=0
    [[ "$header" =~ (^|[[:space:]])kind=([^[:space:]]+) ]] && kind="${BASH_REMATCH[2]}"
    [[ "$header" =~ (^|[[:space:]])n=([0-9]+) ]]           && n="${BASH_REMATCH[2]}"
    [[ "$header" =~ (^|[[:space:]])id=([0-9]+) ]]          && id="${BASH_REMATCH[2]}"
    [[ "$header" =~ (^|[[:space:]])src=([^[:space:]]+) ]]  && src="${BASH_REMATCH[2]}"
    [[ "$header" =~ (^|[[:space:]])path=[^[:space:]] ]]    && haspath=1

    # 1. PR review shapes. `path=` present ⇒ a review COMMENT (its own
    #    endpoint under /pulls/); absent ⇒ a top-level review, which GitHub
    #    gives no reactions endpoint — say so rather than inventing one.
    if [[ "$kind" == "pr_review" ]]; then
        if (( haspath )) && [[ -n "$id" ]]; then
            printf 'review_comment:%s\n' "$id"
            return 0
        fi
        printf 'none:%s\n' "${n:-0}"
        return 0
    fi
    # 2. Body-level mentions — reaction on the issue/PR itself, keyed on n.
    #    `kind=issue_new` is kept alongside `src=body` on purpose: it is the
    #    BACK-COMPAT arm for entries already persisted in
    #    `unacked-mentions.lines` before `_deliveries.sh` started stamping
    #    `src=body`. Without it the live #1499 entry could not be classified
    #    after this fix landed without hand-editing watcher state.
    if [[ "$src" == "body" || "$kind" == "issue_new" ]]; then
        if [[ -n "$n" ]]; then
            printf 'issue:%s\n' "$n"
            return 0
        fi
        printf 'none:0\n'
        return 0
    fi
    # 3. Default: a comment database id. LAST arm by design (see ARM ORDER).
    if [[ -n "$id" ]]; then
        printf 'comment:%s\n' "$id"
        return 0
    fi
    printf 'none:%s\n' "${n:-0}"
    return 0
}

# Backoff-stamp filename stem for a mention block's reaction target
# (your-org/nexus-code#1500).
#
# A COMMENT / REVIEW-COMMENT id is a GLOBAL GitHub database id and needs no
# repo scope — and keeping that spelling byte-identical (`comment-<id>`)
# means every stamp already on disk stays valid across this change, with no
# migration step.
#
# An ISSUE NUMBER is repo-LOCAL. `your-org/nexus-code#1499` and any other
# repo's #1499 would otherwise share one `comment-1499.ts` stamp and
# silently suppress each other's re-emit for a whole backoff window — the
# same collision `_deliveries.sh` already guards with its repo-scoped
# `issue:<repo>:<n>` processed-comments key. So body-level and unresolvable
# targets ARE repo-scoped.
#
# The stem is also the operator-facing artefact: `comment-1499.ts` for what
# was actually issue #1499 is what made #1500 cost twenty minutes to
# localize. `issue-your-org_nexus-code-1499.ts` says what it is.
#
# THIS MERGES TWO REGISTRY ENTRIES ONTO ONE STAMP, AND THAT IS INTENDED —
# named here because an UNNAMED emit-suppression is exactly what #1500 was
# (your-org/nexus-code#1500, skeptic finding F3).
#
# One issue can sit in the registry TWICE, because the two sources spell its
# `id=` differently and `_reemit_register` dedupes on `id=`:
#
#   mention=<r> kind=issue_new n=1499 id=1499        src=body   (deliveries: the NUMBER)
#   mention=<r> kind=issue     n=1499 id=3388812345  src=body   (mention walk: the databaseId)
#
# Pre-change they stamped `comment-1499.ts` and `comment-3388812345.ts` —
# two independent backoff windows. Both now key on `issue:1499` and share
# `issue-<repo>-1499.ts`, so whichever flushes first suppresses the other
# for one MONITOR_REEMIT_BACKOFF_SECONDS window.
#
# WHY THAT IS THE RIGHT SEMANTICS, not merely a tolerable side effect: the
# stamp bounds the emit cadence of a REACTABLE OBJECT, and these two entries
# have the SAME one. A single 👀/🚀 on that issue acks both — the classifier
# returns one verdict for both, and a 🚀 evicts both in the same `_reemit_gc`
# pass. Two entries about one issue backing off independently would emit the
# same issue at twice the intended rate, which is the defect this filter
# exists to prevent.
#
# WHAT IT COSTS: a DELAY, never a loss. The registry gate (`_reemit_pending`)
# is separate and untouched, so the suppressed entry re-emits after the
# window. Bounded honestly: reachable by construction, NOT observed live —
# the primary's registry held exactly one entry for #1499.
_reemit_stamp_stem() {
    local repo="$1" key="$2"
    local type="${key%%:*}" val="${key#*:}"
    case "$type" in
        comment|review_comment)
            printf '%s-%s\n' "$type" "$val"
            ;;
        *)
            local r="${repo//\//_}"
            r="${r//[^A-Za-z0-9._-]/_}"
            printf '%s-%s-%s\n' "$type" "${r:-unknown}" "$val"
            ;;
    esac
}

# Helper for `_filter_reemit_backoff`. Gates a single (header, body_line)
# block. Non-mention shapes and identity-less blocks pass through untouched.
# A `mention=`/`cross_repo=` block is dropped when the stamp for its
# reaction target (`reemit-backoff/<stem>.ts`, see `_reemit_stamp_stem`) is
# younger than the backoff window; otherwise it prints and (re)stamps `now`.
# The stamp tracks actually-emitted state (written only when the block
# proceeds), so the window measures last-emit to now — not last-considered.
_reemit_backoff_flush() {
    local hist_dir="$1" now="$2" backoff="$3" header="$4" body_line="$5"
    if [[ ! "$header" =~ ^(mention|cross_repo)= ]]; then
        printf '%s\n' "$header"
        [[ -n "$body_line" ]] && printf '%s\n' "$body_line"
        return
    fi
    local repo=""
    [[ "$header" =~ ^(mention|cross_repo)=([^[:space:]]+) ]] && repo="${BASH_REMATCH[2]}"
    local key
    key=$(_mention_target_key "$header")
    if [[ "$key" == "none:0" ]]; then
        # Neither `n=` nor `id=` — no identity to key a stamp on. Pass
        # through, exactly as the id-less case always did.
        printf '%s\n' "$header"
        [[ -n "$body_line" ]] && printf '%s\n' "$body_line"
        return
    fi
    local stem
    stem=$(_reemit_stamp_stem "$repo" "$key")
    local stamp_path="$hist_dir/$stem.ts" last=0
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

# Per-surface EDGE damper for `watcher_alert=` blocks
# (your-org/nexus-code#966).
#
# WHY THIS IS NOT A GENERATOR FIX. Every alert generator in `_github.sh`
# is ALREADY edge-triggered and demonstrably works:
# `_graphql_note_failure` prints only when `announced==0` or the remind
# cadence has lapsed, `_graphql_backoff_announce` keys a sentinel file on
# (surface, armed), `_watcher_handle_graphql_failure` keys one on
# (surface, reset), and `_graphql_note_success` deletes the state file as
# it emits. The 2026-08-17 GraphQL 503 measured this exactly: `announced=`
# never moved off its 10:45:41 value, yet 62 pastes went out in the next
# ten minutes, ALL carrying the same frozen `held_s=2403`. One generator
# edge, 62 deliveries.
#
# The defect is delivery, not generation. `_compose_gh_now` `cat`s
# `<stage>/github_poll.out` WITHOUT consuming it (main.sh ~L3995) and
# `github_poll` refreshes that file only every 600 s, so every
# `comment_surface` fire (15 s base, 5 s under the nudge override) re-reads
# the same bytes. That replay is BY DESIGN and correct for comments, which
# the pipeline damps.
#
# WHY NOTHING DAMPED AN ALERT — stated as the predicate that is actually
# true, because the convenient one ("all eight hops key on `id=<N>`") is
# NOT, and a near-true universal is the shape that survives review and then
# misleads the next reader. Every hop dispatches on the recognised emit-
# header shapes `^(issue|pr|pr_review|issue_new|mention|cross_repo)=`.
# `watcher_alert=` matches none of them, so each hop takes its DEFAULT ARM
# and forwards the block untouched. That is the whole mechanism, and it is
# a permissive-default-arm failure, not an id-keying one.
#
# The id-keying is true only of the five DAMPING hops (`_dedup_emit_lines`,
# `_filter_suppression`, `_filter_processed_comments`,
# `_filter_reemit_backoff`, `_filter_emit_cooldown`). The other three key on
# something else entirely — `_filter_to_user_author` on `author=`,
# `_filter_skip_marker` on body content, `_filter_cross_repo_surface` on the
# mention shapes — and would have passed an alert even if it HAD carried an
# `id=`. So "no hop could express an alert" holds; "all eight key on id="
# does not, and fixing the latter would not have been enough.
#
# `_v2_task_comment_surface` then pastes unconditionally (its dedup gate is
# deliberately bypassed for comment-bearing bodies). The storm ended only
# when the 600 s tick happened to replace the staged bytes with an empty
# file — an external event, not a damper.
#
# WHAT THIS ADDS. The identity the pipeline was missing, keyed on the
# surface (the alert's actual state-machine subject) rather than on a
# comment id it will never have. Per surface we remember the last EMITTED
# (kind, content-hash, timestamp) and pass a block when any of:
#
#   * the KIND changed        — a real state edge (`ingest-degraded` ->
#                               `ingest-recovered`). Always passes, never
#                               waits out a cooldown. This is what keeps a
#                               recovery from being swallowed by the hold
#                               its own degraded alert took out, which
#                               would leave the operator unable to tell
#                               "recovered" from "watcher died".
#   * the CONTENT changed     — a re-nag at a new `held_s`, or a new
#                               escalation tier. The generator only
#                               produces these on its own cadence, so
#                               passing them is passing an edge.
#   * the cooldown lapsed     — backstop only, so a future generator that
#                               forgets its own announce-once still cannot
#                               storm indefinitely.
#
# So the emit stream carries one delivery per generator edge, which is the
# symmetry `_graphql_note_success` already had and the escalated side had
# lost somewhere between the generator and the paste.
#
# The default MUST exceed the 600 s `github_poll` staging window, or a
# single staged generation still lands twice; 900 s is that bound plus
# margin. `0` disables (passthrough, zero on-disk footprint) — the
# convention the sibling filters use, and the negative control the test
# suite uses to reproduce `#966` on demand.
#
# Non-alert lines pass through untouched: this filter has no opinion about
# comments, and must never acquire one — damping the operator channel is a
# strictly worse failure than the storm it replaces.
_filter_alert_cooldown() {
    local cooldown="${MONITOR_ALERT_EMIT_COOLDOWN_SECONDS:-900}"
    if ! [[ "$cooldown" =~ ^[0-9]+$ ]]; then
        cooldown=900
    fi
    if (( cooldown == 0 )); then
        cat
        return
    fi
    local hist_dir="${STATE_DIR}/alert-history"
    mkdir -p "$hist_dir" 2>/dev/null || true
    local now
    now=$(date +%s)
    local header="" body_line=""
    local line
    while IFS= read -r line; do
        if [[ "$line" == watcher_alert=* ]]; then
            if [[ -n "$header" ]]; then
                _alert_cooldown_flush "$hist_dir" "$now" "$cooldown" "$header" "$body_line"
                header=""; body_line=""
            fi
            header="$line"
            body_line=""
        elif [[ -n "$header" && -z "$body_line" && "$line" =~ ^[[:space:]]+body: ]]; then
            body_line="$line"
        else
            if [[ -n "$header" ]]; then
                _alert_cooldown_flush "$hist_dir" "$now" "$cooldown" "$header" "$body_line"
                header=""; body_line=""
            fi
            printf '%s\n' "$line"
        fi
    done
    if [[ -n "$header" ]]; then
        _alert_cooldown_flush "$hist_dir" "$now" "$cooldown" "$header" "$body_line"
    fi
}

# Helper for `_filter_alert_cooldown` — gate one (header, body_line) alert
# block. Mirrors `_emit_cooldown_flush`'s per-key flock for the same reason
# it exists there (your-org/nexus-code#562 skeptic finding): `comment_surface`
# and `compose_emit` run this pipeline from CONCURRENT async subshells, so an
# unguarded read-modify-write lets both read a pre-cooldown stamp for the same
# surface, both pass, and the alert double-paste — reintroducing a small
# version of the very storm this filter exists to stop. Bounded (`-w 5`) and
# fail-open, matching the sibling.
_alert_cooldown_flush() {
    local hist_dir="$1" now="$2" cooldown="$3" header="$4" body_line="$5"
    local kind="" surface=""
    [[ "$header" =~ ^watcher_alert=([^[:space:]]+) ]] && kind="${BASH_REMATCH[1]}"
    [[ "$header" =~ surface=([^[:space:]]+) ]] && surface="${BASH_REMATCH[1]}"
    # An alert with no parseable kind is an unknown shape; forward it rather
    # than damp it. Silence is the failure mode this whole file is about.
    if [[ -z "$kind" ]]; then
        printf '%s\n' "$header"
        [[ -n "$body_line" ]] && printf '%s\n' "$body_line"
        return
    fi
    # Key on the SURFACE so kind-vs-kind is a detectable edge. A surfaceless
    # alert keys on its own kind (it is its own state machine).
    local key="${surface:-$kind}"
    local stamp_path="$hist_dir/alert-${key//[^A-Za-z0-9._-]/_}.meta"
    if command -v flock >/dev/null 2>&1; then
        local _af_fd
        if { exec {_af_fd}>"$stamp_path.lock"; } 2>/dev/null; then
            flock -w 5 "$_af_fd" 2>/dev/null || true
            _alert_cooldown_decide "$now" "$cooldown" "$header" "$body_line" "$stamp_path" "$kind"
            exec {_af_fd}>&-
            return
        fi
    fi
    _alert_cooldown_decide "$now" "$cooldown" "$header" "$body_line" "$stamp_path" "$kind"
}

# The unguarded decide+stamp core of `_alert_cooldown_flush`. Callers own
# any locking. Stamps only on PASS, so the window measures last-emitted
# rather than last-considered — same contract as the comment cooldown.
_alert_cooldown_decide() {
    local now="$1" cooldown="$2" header="$3" body_line="$4" stamp_path="$5" kind="$6"
    local sha prev_ts=0 prev_sha="" prev_kind="" drop=0
    sha=$(printf '%s\n%s' "$header" "$body_line" | sha256sum 2>/dev/null | awk '{print $1}')
    if [[ -f "$stamp_path" ]]; then
        prev_ts=$(awk -F= '/^ts=/{print $2; exit}' "$stamp_path" 2>/dev/null)
        prev_sha=$(awk -F= '/^sha=/{sub(/^sha=/, ""); print; exit}' "$stamp_path" 2>/dev/null)
        prev_kind=$(awk -F= '/^kind=/{sub(/^kind=/, ""); print; exit}' "$stamp_path" 2>/dev/null)
        [[ "$prev_ts" =~ ^[0-9]+$ ]] || prev_ts=0
    fi
    # Drop ONLY the exact case the storm is made of: same surface, same
    # kind, byte-identical content, still inside the window.
    if [[ "$kind" == "$prev_kind" && -n "$sha" && "$sha" == "$prev_sha" ]] \
       && (( now - prev_ts < cooldown )); then
        drop=1
    fi
    if (( drop == 0 )); then
        printf '%s\n' "$header"
        [[ -n "$body_line" ]] && printf '%s\n' "$body_line"
        if [[ -n "$sha" ]]; then
            printf 'ts=%s\nkind=%s\nsha=%s\n' "$now" "$kind" "$sha" \
                > "$stamp_path.tmp.$BASHPID" \
                && mv "$stamp_path.tmp.$BASHPID" "$stamp_path" 2>/dev/null || true
        fi
    fi
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
