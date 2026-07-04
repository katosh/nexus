#!/usr/bin/env bash
# Mentions-search fallback for the watcher.
#
# Surfaces cross-repo activity that mentions `github.user_login` in
# repos where the App is NOT installed — the gap the deliveries path
# can't reach. Uses GitHub's GraphQL `search` endpoint with the
# `mentions:<user_login>` qualifier (NOT `mentions:<bot_login>`: the
# qualifier does not index `[bot]` accounts; a definitive negative
# probe documented in `reports/nexus_2026-04-30_231902_watcher-impl-A.md`).
#
# Loaded by `monitor/watcher/main.sh` when `monitor.mentions_enabled`
# is true; otherwise the function definitions are still sourced (for
# reuse by tests + future callers) but `snapshot_mentions` is never
# invoked. Side-effect-free at source time.
#
# Caller globals (set by main.sh before sourcing):
#   STATE_DIR             monitor/.state
#   REPO                  github.repo (skipped — covered by snapshot_github)
#   USER_LOGIN            github.user_login (the mention target)
#   MINT_TOKEN_BIN        path to mint-token.sh (no flag = installation
#                         token; used to populate the bot-installed-
#                         repos cache via /installation/repositories)
#
# Cursor file: monitor/.state/last-mention-cursor.txt. Stores the
# largest `databaseId` seen across all comments + issue bodies on the
# previous poll. On each cycle we ignore items with id <= cursor (they
# were processed already) and update the cursor to the new max.
# Comment ids and issue ids share GitHub's monotonic int sequence per
# table but not across tables; we keep one shared cursor because the
# only purpose is "have we seen something newer than X" — false
# negatives (we re-evaluate an item) are caught by the
# `processed-comments.txt` dedup that follows. False positives
# (skipping an item we should have surfaced) are bounded by GitHub's
# id monotonicity, which holds within each table; cross-table mismatch
# can't manufacture an id higher than something the table actually
# emitted, so the cursor never skips a comment by accident.
#
# Bot-installed-repos cache: monitor/.state/bot-installed-repos.txt.
# Newline-separated `<owner>/<repo>`. Refreshed at most once per 24 h
# via `/installation/repositories` (installation token; same auth as
# `monitor/ng`). Repos in this list are skipped by the mentions path —
# the deliveries path covers them when enabled, and `snapshot_github`
# covers `$REPO` regardless. If the cache file can't be (re)populated
# we fall back to whatever's on disk (even stale) rather than emitting
# duplicates; on first run with no cache and no network, the path
# degrades to "surface mentions in every non-$REPO repo" which is the
# safe direction.
#
# Eligibility filter (per emit candidate):
#   1. Repo != $REPO and not in bot-installed cache.
#   2. Body contains `@USER_LOGIN` with word boundaries.
#   3. databaseId > cursor (cheap optimization — caps walk size after
#      a long stretch of no signal).
#   4. Not in `processed-comments.txt` under the `mention:<id>` (or
#      `mention:issue:<n>` for body matches) prefix. Distinct prefix
#      from the `comment:` / `issue:` keys used by `snapshot_github`
#      and the deliveries path so the same id surfaced via two sources
#      doesn't collide on a confusing key.
#   5. No ROCKET reaction; no EYES reaction by anyone other than
#      USER_LOGIN. Identical to `snapshot_github`'s filter — keeps the
#      surface uniform for downstream `ng process`.
#
# Author filter: NOT enforced here. `_filter_to_user_author` downstream
# is the single chokepoint (issue #86). In practice this path emits
# only when the user self-mentions or comments in a thread where the
# `@USER_LOGIN` appears elsewhere; non-user-authored mentions of the
# user (the previous use case) are dropped at the chokepoint by
# design — an accepted loss documented on issue #86.
#
# Line shape emitted (one per match, plus a body preview line):
#
#   cross_repo=<owner>/<repo> kind=<issue|pr> n=<n> id=<id> author=<login> [src=body]
#     body: <truncated to 400 chars>
#
# `src=body` distinguishes the rare "mention is in the issue body
# itself" emit from the common "mention is in a comment". Without it,
# downstream couldn't tell whether `id=<n>` refers to the issue itself
# or a comment that happens to be in the issue's table.
#
# `cross_repo=` is a NEW line shape, distinct from `mention=` emitted
# by the deliveries path. The two have different provenance:
#
#   mention=    -> from the App's own webhook delivery log; implies the
#                  bot is installed on the source repo (so it can
#                  comment back, react, etc).
#   cross_repo= -> from a search hit in a repo where the bot is NOT
#                  installed; the bot CANNOT comment back without
#                  someone first installing it. Routing logic should
#                  treat `cross_repo=` as read-only context until a
#                  human installs the bot on the source repo.
#
# This distinction is documented at-length in
# `config/nexus.example.yml`'s `monitor.mentions_enabled` block.

snapshot_mentions() {
    local cursor_file="${STATE_DIR}/last-mention-cursor.txt"
    local cursor=0
    if [[ -f "$cursor_file" ]]; then
        cursor=$(<"$cursor_file")
        [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
    fi

    [[ -n "${USER_LOGIN:-}" ]] || {
        echo "snapshot_mentions: USER_LOGIN unset; skipping cycle" >&2
        return 0
    }

    local processed_file="${STATE_DIR}/processed-comments.txt"
    local processed_content=""
    [[ -f "$processed_file" ]] && processed_content=$(<"$processed_file")

    # Bot-installed repos cache. Newline-separated `owner/repo`. Empty
    # string is fine — every repo will be eligible (modulo the $REPO
    # skip below).
    local bot_repos
    bot_repos=$(_bot_installed_repos_cache)

    # Search query. `sort:updated-desc` makes the response newest-first
    # so the cursor short-circuit drops most of the page on a quiet
    # cycle. `first: 50` bounds the per-cycle cost; if more matches
    # accumulate between polls than fit on one page, the cursor still
    # advances correctly (we update to max id in the page) and the
    # next cycle catches up.
    # WEDGE-SAFETY (your-org/nexus-code#367): bound this `gh api graphql`
    # with `timeout` — it rides the same async `github_poll` task as
    # `snapshot_github`, and `gh api graphql` honours no curl timeout
    # flag, so an unbounded hung request here would freeze the scheduler
    # exactly like the snapshot_github calls did. `snapshot_bot_mentions`
    # below is already curl-`--max-time`-bounded; this is the matching
    # guard for the `gh`-based user-mention search. A timeout exits
    # non-zero and the existing `|| { skipping cycle }` handles it
    # gracefully (retry next cycle).
    local raw
    raw=$(timeout -k "${GRAPHQL_TIMEOUT_KILL_AFTER:-5}" "${GRAPHQL_TIMEOUT:-30}" \
        gh api graphql \
        -f query='
          query($q: String!) {
            search(type: ISSUE, query: $q, first: 50) {
              nodes {
                ... on Issue {
                  __typename
                  number
                  databaseId
                  author { login }
                  body
                  repository { nameWithOwner }
                  reactions(first: 50) {
                    nodes { content user { login } }
                  }
                  comments(last: 50) {
                    nodes {
                      databaseId
                      author { login }
                      body
                      reactions(first: 10) {
                        nodes { content user { login } }
                      }
                    }
                  }
                }
                ... on PullRequest {
                  __typename
                  number
                  databaseId
                  author { login }
                  body
                  repository { nameWithOwner }
                  reactions(first: 50) {
                    nodes { content user { login } }
                  }
                  comments(last: 50) {
                    nodes {
                      databaseId
                      author { login }
                      body
                      reactions(first: 10) {
                        nodes { content user { login } }
                      }
                    }
                  }
                }
              }
            }
          }' \
        -f q="mentions:${USER_LOGIN} sort:updated-desc" 2>/dev/null) || {
        echo "snapshot_mentions: graphql call failed; skipping cycle" >&2
        return 0
    }

    [[ -n "$raw" ]] || return 0

    # Walk + emit via the shared core. The user-mention path SKIPS
    # installed repos (the deliveries / bot-mention paths own those),
    # matches on the operator's own handle, and emits the read-only
    # `cross_repo=` vocabulary. The EYES-exempt self login is the
    # operator (here the handle and the self login coincide).
    local extracted
    extracted=$(_mention_walk "$raw" "$USER_LOGIN" "$USER_LOGIN" \
                              "skip" "mention" "$cursor" "$bot_repos" "$processed_content")
    [[ -n "$extracted" ]] || return 0

    _mention_emit_loop "cross_repo" "$cursor" "$cursor_file" <<<"$extracted"
}

# Returns newline-separated `owner/repo` of every repo the App is
# installed on. Cached for 24 h at $STATE_DIR/bot-installed-repos.txt.
# On any failure (no token, network error, jq parse failure) returns
# whatever's on disk — even stale — to bias toward NOT emitting
# duplicates. First-run-with-no-network returns empty (every repo is
# eligible), which is the safe direction (false positive = one extra
# emit; false negative = silently lose a notification).
_bot_installed_repos_cache() {
    local cache_file="${STATE_DIR}/bot-installed-repos.txt"
    local age=999999999
    [[ -f "$cache_file" ]] && age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if (( age < 86400 )); then
        cat "$cache_file"
        return 0
    fi
    # Refresh path. Need an installation token; mint via the same
    # script the rest of the watcher uses.
    local token
    if [[ -n "${MINT_TOKEN_BIN:-}" && -x "${MINT_TOKEN_BIN}" ]]; then
        token=$("$MINT_TOKEN_BIN" 2>/dev/null) || token=""
    else
        token=""
    fi
    if [[ -z "$token" ]]; then
        [[ -f "$cache_file" ]] && cat "$cache_file"
        return 0
    fi
    local repos
    # `gh api --paginate` with `--jq` runs the filter per page, so the
    # output is one repo per line across all pages.
    #
    # WEDGE-SAFETY (your-org/nexus-code#367): this REST refresh runs on
    # the same async github_poll task (via snapshot_mentions) as the
    # bounded graphql calls. Bound it with the SAME `timeout` ceiling so
    # a hung / black-holed `/installation/repositories` can't freeze the
    # scheduler. On timeout it exits non-zero; the existing `|| repos=""`
    # + fallback below keeps the (even stale) on-disk cache — never
    # blocks, retries next cycle.
    local _gt="${GRAPHQL_TIMEOUT:-30}"; [[ "$_gt" =~ ^[0-9]+$ && "$_gt" -gt 0 ]] || _gt=30
    local _gk="${GRAPHQL_TIMEOUT_KILL_AFTER:-5}"; [[ "$_gk" =~ ^[0-9]+$ ]] || _gk=5
    repos=$(GH_TOKEN="$token" timeout -k "$_gk" "$_gt" gh api --paginate /installation/repositories \
              --jq '.repositories[].full_name' 2>/dev/null) || repos=""
    if [[ -n "$repos" ]]; then
        printf '%s\n' "$repos" > "$cache_file"
        printf '%s\n' "$repos"
    else
        [[ -f "$cache_file" ]] && cat "$cache_file"
    fi
}

# ===========================================================================
# Shared core for the two mention-search paths (snapshot_mentions and
# snapshot_bot_mentions). These two paths differ ONLY in their search
# surface (the `mentions:<user>` qualifier vs the literal `"@<bot>"`
# string), their transport (`gh api graphql` vs a timeout-bounded curl),
# their repo scope (skip-installed vs keep-installed), and their emit
# vocabulary (`cross_repo=` vs `mention=`). EVERYTHING else — the
# word-boundary mention regex, the ROCKET/non-self-EYES suppression, the
# cursor short-circuit, the processed-comments dedup, the body+comment
# emit shape, the 400-char body preview, and the cursor advance — is
# identical and lives here ONCE. A fix to the regex / reaction rule /
# dedup logic now lands in a single place instead of two (the redundancy
# that confused the operator on 2026-06-23; see PR consolidating #339).

# Walk a GraphQL `search` response and emit one compact-JSON candidate
# per eligible mention. Reads $1 (raw JSON) on a here-string; writes the
# candidate objects to stdout. All four divergent axes are arguments so
# the body is shared verbatim between both callers.
#
# Args:
#   $1 raw         raw GraphQL JSON ({ data: { search: { nodes: [...] } } })
#   $2 handle      the @handle to match (USER_LOGIN, or the bot slug)
#   $3 self_login  the login whose EYES reaction does NOT block — always
#                  the OPERATOR (USER_LOGIN); their own 👀 isn't a veto
#   $4 scope       "skip" → drop installed repos; "keep" → only installed
#   $5 prefix      processed-comments dedup namespace ("mention"|"botmention")
#   $6 cursor      integer databaseId floor (items <= it were seen already)
#   $7 bot_repos   newline-separated installed `owner/repo` cache
#   $8 processed   processed-comments.txt content
_mention_walk() {
    local raw="$1" handle="$2" self_login="$3" scope="$4" prefix="$5"
    local cursor="$6" bot_repos="$7" processed="$8"
    jq -c --arg handle "$handle" \
          --arg repo "$REPO" \
          --arg bot_repos "$bot_repos" \
          --arg self "$self_login" \
          --arg scope "$scope" \
          --arg pfx "$prefix" \
          --arg processed "$processed" \
          --argjson cursor "$cursor" '
        ($bot_repos | split("\n") | map(select(. != ""))) as $bots
        | ($processed | split("\n") | map(select(. != ""))) as $proc
        | def mention_re: "(^|[^[:alnum:]_])@" + $handle + "([^[:alnum:]_-]|$)";
          def has_mention(s): ((s // "") | test(mention_re; "i"));
          def has_blocking_reaction(rs):
              ([rs[]? | select(.content == "ROCKET"
                               or (.content == "EYES" and .user.login != $self))]
               | length) > 0;
          # Repo scope: "keep" surfaces only installed repos (the bot can
          # act there); "skip" drops them (the deliveries/bot paths own
          # those). An empty cache makes "keep" emit nothing and "skip"
          # surface everywhere — the safe direction for each.
          def in_scope($r):
              if $scope == "keep" then (($bots | index($r)) != null)
              else (($bots | index($r)) | not) end;
          .data.search.nodes[]?
        | . as $node
        | ($node.repository.nameWithOwner // "") as $r
        | select($r != "" and $r != $repo)
        | select(in_scope($r))
        | (if ($node.__typename // "") == "PullRequest" then "pr" else "issue" end) as $kind
        | (
            # Issue/PR body mention.
            (
              if has_mention($node.body)
                 and (($node.databaseId // 0) > $cursor)
                 and (($proc | index($pfx + ":issue:" + ($node.number|tostring))) | not)
                 and (has_blocking_reaction($node.reactions.nodes) | not)
              then
                { src: "body", repo: $r, kind: $kind,
                  n: ($node.number | tostring), id: ($node.databaseId | tostring),
                  author: ($node.author.login // ""), body: ($node.body // "") }
              else empty end
            ),
            # Per-comment mention emits.
            (
              $node.comments.nodes[]?
              | . as $c
              | select(($c.databaseId // 0) > $cursor)
              | select(has_mention($c.body))
              | select(($proc | index($pfx + ":" + ($c.databaseId | tostring))) | not)
              | select(has_blocking_reaction($c.reactions.nodes) | not)
              | { src: "comment", repo: $r, kind: $kind,
                  n: ($node.number | tostring), id: ($c.databaseId | tostring),
                  author: ($c.author.login // ""), body: ($c.body // "") }
            )
          )
    ' <<<"$raw" 2>/dev/null
}

# Print the watcher emit block for each candidate read on stdin (the
# compact-JSON objects emitted by `_mention_walk`) and advance the path's
# cursor file to the max databaseId seen. Identical across both paths
# except the header verb. Runs in the caller's shell (here-string input)
# so the cursor-file write is a direct side effect, matching the original
# inlined loops.
#
# Args:
#   $1 verb         emit header prefix ("cross_repo" | "mention")
#   $2 cursor       current cursor (for the no-advance short-circuit)
#   $3 cursor_file  path to persist the advanced cursor
_mention_emit_loop() {
    local verb="$1" cursor="$2" cursor_file="$3"
    local newest_id="$cursor"
    local line repo kind n id author body src body_preview extra
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        repo=$(jq -r   '.repo   // ""' <<<"$line")
        kind=$(jq -r   '.kind   // ""' <<<"$line")
        n=$(jq -r      '.n      // ""' <<<"$line")
        id=$(jq -r     '.id     // ""' <<<"$line")
        author=$(jq -r '.author // ""' <<<"$line")
        body=$(jq -r   '.body   // ""' <<<"$line")
        src=$(jq -r    '.src    // ""' <<<"$line")
        [[ -n "$repo" && -n "$kind" && -n "$n" && -n "$id" ]] || continue

        body_preview=$(printf '%s' "$body" | tr '\n\r\t' '   ' | head -c 400)
        if (( ${#body} > 400 )); then
            body_preview="${body_preview}…"
        fi

        # `src=body` only on body matches (id is then the issue/PR id, not
        # a comment id). Absence of `src=` means the id is a comment id.
        extra=""
        [[ "$src" == "body" ]] && extra=" src=body"

        printf '%s=%s kind=%s n=%s id=%s author=%s%s\n  body: %s\n' \
            "$verb" "$repo" "$kind" "$n" "$id" "$author" "$extra" "$body_preview"

        if [[ "$id" =~ ^[0-9]+$ ]] && (( id > newest_id )); then
            newest_id="$id"
        fi
    done

    if [[ "$newest_id" != "$cursor" ]]; then
        # Atomic tmp+mv (your-org/nexus-code#360) — match the delivery cursor
        # (`_write_delivery_cursor`). A bare `>` truncates then writes, so a
        # crash / NFS hiccup mid-write could leave a partial/empty cursor; the
        # next read parses it as 0 and re-walks the whole search page. tmp+mv
        # makes a half-written cursor impossible; best-effort so an FS error
        # can't abort the caller.
        printf '%s\n' "$newest_id" > "${cursor_file}.tmp" 2>/dev/null \
            && mv "${cursor_file}.tmp" "$cursor_file" 2>/dev/null || true
    fi
}

# ===========================================================================
# Bot-mention cross-repo search (snapshot_bot_mentions).
#
# THE GAP THIS CLOSES. There are three other cross-repo surfacing paths,
# and an `@<bot>`-mention the operator posts on an INSTALLED non-asset
# repo (e.g. your-org/nexus-code) falls through every one of them:
#
#   - snapshot_github      → only $REPO (the asset repo). ✗
#   - snapshot_deliveries  → @bot-mentions on installed repos via the App
#       WEBHOOK, surfaced as `mention=`. But it needs an App webhook URL
#       (the live App has none → 404) and was disabled after wedging the
#       loop 3× on 2026-06-20. ✗ when deliveries.bot_mention_enabled=false.
#   - snapshot_mentions    → cross-repo, but keyed on the `mentions:<user>`
#       qualifier (does NOT index the bot) AND explicitly SKIPS installed
#       repos (they were the deliveries path's job). ✗
#
# Net: with the webhook off, an operator @bot-mention on an installed
# non-asset repo had NO live channel. That is exactly why comment
# 4780061875 on your-org/nexus-code#334 went silent.
#
# This function is the webhook-FREE, poll-based equivalent of the
# deliveries path, scoped IDENTICALLY: installed repos other than $REPO,
# surfaced as the `mention=` shape (the bot is installed there, so it CAN
# reply — `mention=` is the actionable shape; `cross_repo=` is read-only
# context for non-installed repos and is NOT used here). Found via
# GitHub's GraphQL `search` over the LITERAL bot handle string
# `"@<bot_slug>"`. Free-text search DOES index `@<bot>` body/comment text
# even though the `mentions:` qualifier does not index `[bot]` accounts —
# an empirically-confirmed positive: the query returns
# your-org/nexus-code#334 as a top hit at a measured cost of 1 GraphQL
# point per search.
#
# WEDGE-SAFETY (mirrors the deliveries fix — load-bearing). The single
# GraphQL request is a raw `curl` bounded by
# `--connect-timeout MENTIONS_CONNECT_TIMEOUT` (default 5s) AND
# `--max-time MENTIONS_MAX_TIME` (default 20s). A slow / hung /
# black-holed endpoint can no longer block the call indefinitely; it
# exits non-zero within the budget and the whole cycle returns 0
# (NON-FATAL skip — never blocks the main loop or snapshot_github). We
# deliberately do NOT use `gh api graphql` here: it honours neither
# timeout knob, so a black-holed connection could hang until the
# scheduler's async hang-watchdog (300s) reaped it — the original
# deliveries wedge. The enclosing `github_poll` task is async (watchdog
# floor applies) and already gated by `_graphql_polling_gate`, so a
# draining GraphQL bucket skips the fire before this runs.
#
# Loaded by main.sh; invoked from `_snapshot_github_raw` only when
# `monitor.bot_mentions_enabled` is true. Side-effect-free at source.
#
# Caller globals (set/exported by main.sh):
#   STATE_DIR REPO BOT_LOGIN USER_LOGIN MINT_TOKEN_BIN
#   MENTIONS_CONNECT_TIMEOUT MENTIONS_MAX_TIME
#
# Cursor file: monitor/.state/last-bot-mention-cursor.txt (independent of
# the user-mention cursor). Same monotonic-databaseId semantics as
# snapshot_mentions. Dedup prefix: `botmention:<id>` (comment) /
# `botmention:issue:<n>` (body) — distinct from the `mention:` /
# `comment:` / `issue:` keys used by the other sources so the same id
# surfaced via two sources doesn't collide on a confusing key; the
# cross-source `_dedup_emit_lines` still collapses the duplicate `id=`.
#
# Line shape (folds into the deliveries `mention=` vocabulary):
#   mention=<owner>/<repo> kind=<issue|pr> n=<n> id=<id> author=<login> [src=body]
#     body: <truncated to 400 chars>
snapshot_bot_mentions() {
    # Empty-handle guard (load-bearing now the channel is default-ON). With
    # no `github.bot_login` there is no `@<handle>` to search for, so the
    # safe and correct behaviour is a clean per-cycle no-op: return BEFORE
    # building or issuing any GraphQL request — the empty-handle search is
    # NEVER sent (an `@` query with no slug would be malformed). This is
    # silent on purpose: main.sh logs a SINGLE startup warning when
    # bot_mentions is enabled with an empty bot_login, so re-warning here
    # every poll cycle would only spam the log.
    local bot_slug="${BOT_LOGIN:-}"
    bot_slug="${bot_slug%\[bot\]}"
    [[ -n "$bot_slug" ]] || return 0

    local cursor_file="${STATE_DIR}/last-bot-mention-cursor.txt"
    local cursor=0
    if [[ -f "$cursor_file" ]]; then
        cursor=$(<"$cursor_file")
        [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
    fi

    local processed_file="${STATE_DIR}/processed-comments.txt"
    local processed_content=""
    [[ -f "$processed_file" ]] && processed_content=$(<"$processed_file")

    # Installed-repos cache. We KEEP only repos in this list (the inverse
    # of snapshot_mentions, which skips them) — the bot can only act where
    # it is installed, so a `mention=` from a non-installed repo would be
    # a false promise. An empty cache (no token / no network on first run)
    # therefore yields no emits: the safe direction (no false `mention=`).
    local bot_repos
    bot_repos=$(_bot_installed_repos_cache)

    local connect_to="${MENTIONS_CONNECT_TIMEOUT:-5}"
    local max_time="${MENTIONS_MAX_TIME:-20}"
    [[ "$connect_to" =~ ^[0-9]+$ ]] || connect_to=5
    [[ "$max_time"   =~ ^[0-9]+$ ]] || max_time=20

    # Installation token for the bounded curl. Same auth as `monitor/ng`
    # and `_bot_installed_repos_cache`. A mint failure is a non-fatal skip.
    local token=""
    if [[ -n "${MINT_TOKEN_BIN:-}" && -x "${MINT_TOKEN_BIN}" ]]; then
        token=$("$MINT_TOKEN_BIN" 2>/dev/null) || token=""
    fi
    [[ -n "$token" ]] || {
        echo "snapshot_bot_mentions: token mint failed; skipping cycle (non-fatal)" >&2
        return 0
    }

    # Same nested node shape as snapshot_mentions. `sort:updated-desc`
    # makes the page newest-first so the cursor short-circuit drops most
    # of it on a quiet cycle; `first: 50` bounds per-cycle cost.
    local gql='query($q: String!) {
      search(type: ISSUE, query: $q, first: 50) {
        nodes {
          ... on Issue {
            __typename number databaseId author { login } body
            repository { nameWithOwner }
            reactions(first: 50) { nodes { content user { login } } }
            comments(last: 50) {
              nodes { databaseId author { login } body
                      reactions(first: 10) { nodes { content user { login } } } }
            }
          }
          ... on PullRequest {
            __typename number databaseId author { login } body
            repository { nameWithOwner }
            reactions(first: 50) { nodes { content user { login } } }
            comments(last: 50) {
              nodes { databaseId author { login } body
                      reactions(first: 10) { nodes { content user { login } } } }
            }
          }
        }
      }
    }'
    # Build the JSON request body with jq so the query string and the
    # quoted `"@<slug>"` search term are escaped correctly.
    local req
    req=$(jq -n --arg query "$gql" \
                --arg q "\"@${bot_slug}\" sort:updated-desc" \
                '{query: $query, variables: {q: $q}}') || {
        echo "snapshot_bot_mentions: failed to build request body; skipping cycle" >&2
        return 0
    }

    # GUARD: --connect-timeout + --max-time bound this curl. A hung
    # endpoint exits non-zero within the budget; we skip the cycle.
    local raw
    raw=$(curl -sS \
        --connect-timeout "$connect_to" --max-time "$max_time" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -X POST "https://api.github.com/graphql" \
        -d "$req" 2>/dev/null) || {
        echo "snapshot_bot_mentions: graphql curl failed/timed out (connect=${connect_to}s max=${max_time}s) — skipping cycle (non-fatal)" >&2
        return 0
    }
    [[ -n "$raw" ]] || return 0

    # Walk + emit via the shared core. The bot-mention path KEEPS only
    # installed repos (the inverse of snapshot_mentions — the bot can only
    # act where it is installed), matches on the bot slug, and emits the
    # actionable `mention=` vocabulary. The EYES-exempt self login is the
    # OPERATOR (USER_LOGIN), not the bot — an operator 👀 on their own
    # @bot-mention shouldn't veto it.
    local extracted
    extracted=$(_mention_walk "$raw" "$bot_slug" "${USER_LOGIN:-}" \
                              "keep" "botmention" "$cursor" "$bot_repos" "$processed_content")
    [[ -n "$extracted" ]] || return 0

    _mention_emit_loop "mention" "$cursor" "$cursor_file" <<<"$extracted"
}
