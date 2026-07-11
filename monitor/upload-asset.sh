#!/usr/bin/env bash
# Push a local file into the nexus asset repo's `main` branch and
# print a browser-renderable URL pinned to the resulting commit SHA.
#
# URL forms (the SHA is the post-push HEAD of the asset repo):
#     image / pdf / csv / etc:   https://github.com/{owner}/{repo}/raw/<sha>/<path>
#     markdown (.md) / ipynb:    https://github.com/{owner}/{repo}/blob/<sha>/<path>
#
# `raw/<sha>/<path>` is the embed-friendly shape — same-domain
# redirect to a viewer-session-bound signed CDN URL, which renders
# inline in markdown via `![alt](...)` and works on private repos
# in any browser logged into github.com.
#
# `blob/<sha>/<path>` is the link-friendly shape for `.md` and
# `.ipynb`, where github.com renders the content as a page.
#
# Both URLs pin to the commit SHA at upload time, so subsequent
# pushes to the same path do NOT change what the URL resolves to —
# permalinks survive overwrites. To get a "latest" link instead,
# pass `--shape latest` (emits `blob/main/<path>` or `raw/main/<path>`).
#
# Asset tree layout (under the asset repo root):
#   assets/<issue-N>/<basename>            issue-tied (use --issue N)
#   assets/reports/<basename>              reports/ source path
#   assets/general/<basename>              everything else
#   <free-form>                            override via --repo-path
#
# Storage:
#   - Asset repo is maintained as a local clone at `assets/` under
#     the nexus root (gitignored).
#   - Concurrency model (lock-free staging + flock-elected batch
#     manager): every upload first publishes a snapshot of its file +
#     a request marker into `<assets-dir>.staging/` with an atomic
#     rename (no lock needed). It then blocks on a single flock; the
#     holder ("manager") syncs the clone to the remote tip, commits
#     each staged request, does ONE push for the whole batch, and only
#     AFTER the push writes each request's resulting URL into a
#     per-request result file. Every upload finally reads its own
#     result file and prints the URL. This amortises N uploads into ~1
#     push instead of N serial round-trips, while keeping the
#     one-writer-per-push safety that prevents the dangling-SHA
#     breakage in your-org/your-nexus#244. flock is kernel-backed, so
#     a manager that dies mid-batch auto-releases the lock and the next
#     waiter re-drains its leftover markers — no hand-rolled liveness.
#     See the block comment above the STAGE/ELECT/DRAIN/COLLECT phases.
#
# Usage:
#   monitor/upload-asset.sh <local_path>
#                          [--issue N]                  (route under assets/<N>/)
#                          [--repo-path <path>]         (override default placement, asset-repo-root-relative)
#                          [--shape pin|latest]         (pin = blob/raw/<sha>/...; latest = blob/raw/main/...; default pin)
#                          [--message <commit msg>]
#
# Defaults:
#   --repo       from config github.asset_repo, fallback github.repo (env: NEXUS_ASSET_REPO)
#   --shape      pin (SHA-pinned permalink)
#   --repo-path  derived from --issue / source-path / basename (see "Asset tree layout")
#   --message    "Add asset <basename> via upload-asset.sh"
#
# Exit codes:
#   0  url printed on stdout
#   1  bad usage
#   2  mint-token.sh failed
#   3  asset-repo clone/pull/push failed

set -euo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_nexus_root=$(cd "$_script_dir/.." && pwd)
_cfg="$_nexus_root/config/load.sh"

# Asset repo: prefer github.asset_repo; fall back to github.repo for
# back-compat with configs that haven't been split yet.
REPO="${NEXUS_ASSET_REPO:-$("$_cfg" github.asset_repo "$("$_cfg" github.repo)")}"
LOCAL=""
ISSUE=""
REPO_PATH=""
SHAPE="pin"
MESSAGE=""
ASSETS_DIR="$_nexus_root/assets"

usage() { awk '/^$/{exit}NR>1' "$0" >&2; exit "${1:-1}"; }

while (( $# > 0 )); do
    case "$1" in
        --repo)        REPO="$2"; shift 2 ;;
        --issue)       ISSUE="$2"; shift 2 ;;
        --repo-path)   REPO_PATH="$2"; shift 2 ;;
        --shape)       SHAPE="$2"; shift 2 ;;
        --message)     MESSAGE="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        --)            shift; break ;;
        -*)            echo "unknown flag: $1" >&2; usage 1 ;;
        *)             if [[ -z "$LOCAL" ]]; then
                           LOCAL="$1"
                       elif [[ -z "$REPO_PATH" ]]; then
                           REPO_PATH="$1"
                       else
                           echo "unknown positional: $1" >&2; usage 1
                       fi
                       shift ;;
    esac
done

[[ -n "$LOCAL" ]] || usage 1
[[ -f "$LOCAL" ]] || { echo "not a file: $LOCAL" >&2; exit 1; }
case "$SHAPE" in
    pin|latest) ;;
    *) echo "--shape must be pin|latest, got: $SHAPE" >&2; usage 1 ;;
esac

BASENAME="$(basename "$LOCAL")"
if [[ -z "$REPO_PATH" ]]; then
    if [[ -n "$ISSUE" ]]; then
        REPO_PATH="assets/$ISSUE/$BASENAME"
    else
        case "$LOCAL" in
            reports/*|*/reports/*) REPO_PATH="assets/reports/$BASENAME" ;;
            *)                     REPO_PATH="assets/general/$BASENAME" ;;
        esac
    fi
fi

# Normalise REPO_PATH: a leading `assets/` is optional. Callers may
# pass either `assets/<rest>` (fully qualified) or `<rest>` (will be
# placed under assets/<rest>). The push always lands under assets/.
case "$REPO_PATH" in
    assets/*) ;;
    *)        REPO_PATH="assets/$REPO_PATH" ;;
esac

[[ -n "$MESSAGE" ]] || MESSAGE="Add asset $BASENAME via upload-asset.sh"

TOKEN="$("$_script_dir/mint-token.sh")" || { echo "mint-token.sh failed" >&2; exit 2; }
ASSET_URL_AUTH="https://x-access-token:${TOKEN}@github.com/${REPO}.git"
ASSET_URL_NOAUTH="https://github.com/${REPO}.git"

# Git author identity for the asset commit. No hardcoded operator fallback:
# prefer explicit config (github.bot_git_name/_email, documented in
# nexus.example.yml); otherwise derive the GitHub-App "<login>[bot]" author
# convention from github.bot_login (which every operator sets). Fail loud if
# none resolves — a wrong identity mis-attributes commits and breaks
# notification routing.
_bot_login="$("$_cfg" github.bot_login "")"
BOT_NAME="$("$_cfg" github.bot_git_name "${_bot_login:+${_bot_login}[bot]}")"
BOT_EMAIL="$("$_cfg" github.bot_git_email "${_bot_login:+${_bot_login}[bot]@users.noreply.github.com}")"
[[ -n "$BOT_NAME" && -n "$BOT_EMAIL" ]] || {
    echo "upload-asset.sh: cannot determine bot git identity — set github.bot_login (or github.bot_git_name/_email) in nexus config (see config/nexus.example.yml)" >&2
    exit 2
}

# The manager holds the global asset lock on fd $_LOCK_FD (see ELECT below).
# Every `git` invocation in this script MUST go through _git_hardened, which
# applies the three guards that together close your-org/nexus-code#468.
#
# ELECT does `exec {_LOCK_FD}>"$_LOCK"`, which OVERWRITES this placeholder with
# whatever free fd bash picks. Never hardcode the number: the close below and
# the flock calls all read this variable, so they cannot drift apart. The
# placeholder exists only so `set -u` tolerates a _git_hardened call before
# ELECT (there is none today); closing a not-yet-open fd is a harmless no-op.
_LOCK_FD=9

# _git_hardened — the ONLY way this script may invoke git.
#
#  1. `-c credential.helper=` (empty value RESETS the helper list). We embed a
#     freshly-minted installation token in the remote URL, so a credential
#     cache buys nothing — and costs everything: `git push` otherwise forks
#     `git-credential-cache--daemon`, which is what leaked the lock. It would
#     also cache an EXPIRED token and re-serve it. No helper, no daemon.
#
#  2. `GIT_TERMINAL_PROMPT=0` — when the installation token expires mid-batch
#     (~1 h TTL), git falls through to an interactive credential prompt. With
#     no stdin it blocks forever at 0% CPU *while holding the lock*. This is
#     the single change that turns a silent multi-hour outage into an
#     immediate, attributable non-zero exit.
#
#  3. `${_LOCK_FD}>&-` — close the flock fd in the child. flock(2) attaches to
#     the OPEN FILE DESCRIPTION, not to the process, so ANY child inheriting
#     fd 9 holds the lock. Numbered fds >= 3 are inherited across fork+exec
#     unless FD_CLOEXEC is set, and bash does not set it. The credential
#     daemon then setsid()s and reparents to init, holding the lock for hours
#     after every process involved in the upload has exited (observed: 2h37m).
#     bash 4.x cannot mark an already-`exec`-opened fd O_CLOEXEC, so
#     close-at-spawn is the mechanism — identical to the #451 instance-lock
#     fix (`{INSTANCE_LOCK_FD}>&-`). Guard 1 removes today's daemon; this
#     denies the fd to every future child, named or not.
#
# Guards 1 and 3 are independent on purpose. Guard 1 alone regresses the
# instant anything else in the git invocation forks a long-lived helper
# (a pager, a filter, an askpass); guard 3 alone leaves an expired token
# cached and re-served. Neither subsumes the other.
_git_hardened() {
    GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= "$@" {_LOCK_FD}>&-
}

_git_assets() {
    _git_hardened -C "$ASSETS_DIR" \
        -c "user.name=${BOT_NAME}" \
        -c "user.email=${BOT_EMAIL}" \
        "$@"
}

# ---------------------------------------------------------------------------
# Concurrency model: lock-free staging + flock-elected batch manager.
#
# The asset repo is ONE working tree ($ASSETS_DIR) shared by every worker
# running from the same nexus checkout. The original failure (the
# dangling-SHA breakage in your-org/your-nexus#244): two concurrent uploads
# race on that tree — worker B's `reset --hard origin/main` moves HEAD out
# from under worker A between A's commit and A's push/rev-parse, so the SHA A
# pins in its URL never becomes an ancestor of pushed `main` and the embed
# 404s. A plain exclusive flock around the whole flow is correct but
# serialises N uploads into N network round-trips: ten figures means ten
# sequential fetch+push cycles, and the last worker waits for all ten.
#
# This model keeps the one-writer-per-push safety but amortises the push:
#
#   1. STAGE   (lock-free): atomically drop a snapshot of the file + a
#              request marker into $STAGING_DIR. Concurrent stages never
#              contend; the marker is published with an atomic rename, so a
#              draining manager only ever sees complete requests.
#   2. ELECT   (flock): block (bounded) on one exclusive flock. Whoever
#              holds it is the "manager" for that moment.
#   3. DRAIN   (manager, under lock): sync the tree to origin/main, then for
#              each staged marker copy its blob in, `add`, and `commit` with
#              that request's own message — one commit per request preserves
#              per-request SHA + message semantics and avoids the
#              same-path/different-content collision a single squashed commit
#              would create. Then ONE push for the whole chain. Only AFTER
#              the push succeeds, write each request's URL into its result
#              file and remove its marker.
#   4. COLLECT: read this request's own result file and print the URL.
#
# Reliability / failure modes:
#   - Manager death (crash/SIGKILL/OOM) holding the lock: flock is
#     kernel-backed, so the lock auto-releases when the FD closes on death.
#     The next blocked worker acquires it and becomes manager. Markers are
#     removed only AFTER their result is written (only AFTER push), so a dead
#     manager leaves in-flight markers in place and the new manager re-drains
#     them. No PID-liveness probe, no lock-mtime heuristic, no hand-rolled
#     takeover — the kernel is the liveness oracle.
#   - Partial result-write (pushed, then died before writing every result):
#     the pushed commits are on origin; the new manager's
#     `reset --hard origin/main` lands on a HEAD that already holds them, so
#     re-draining a surviving marker finds its content present (no-op add →
#     pins the existing HEAD) or re-commits it cleanly. Idempotent.
#   - Late arrival (marker staged after the manager snapshotted): the marker
#     persists; its own stager acquires the lock and drains it. Every worker
#     that stages also attempts the lock at least once, so no marker is ever
#     orphaned.
#   - Push contention from a DIFFERENT clone (the flock only serialises
#     within one shared tree): the push is retried under bounded exponential
#     backoff with jitter after re-syncing; a hard ceiling then fails loud.
#   - Hung (not dead) lock holder: `flock -w` bounds the wait; on timeout we
#     fail loud rather than spin forever.
#
# Dangling-SHA invariant: a URL is emitted only from a result file, a result
# file is written only AFTER `git push` returns 0, and the SHA it pins is a
# commit in the just-pushed chain. A URL can therefore never name a commit
# absent from the remote. Worker-facing contract is unchanged:
# `url=$(ng upload <file>)` — all coordination is internal, no new flags.
# ---------------------------------------------------------------------------

STAGING_DIR="${ASSETS_DIR}.staging"
_LOCK="${ASSETS_DIR}.lock"
LOCK_WAIT="${NEXUS_UPLOAD_LOCK_WAIT:-180}"        # max seconds to block for the lock
PUSH_RETRIES="${NEXUS_UPLOAD_PUSH_RETRIES:-5}"    # bounded push retries on remote contention
SYNC_RETRIES="${NEXUS_UPLOAD_SYNC_RETRIES:-5}"    # bounded sync retries on transient fetch/reset contention

build_url() {
    # build_url <repo> <repo_path> <shape> <sha> — prints the renderable URL.
    local repo="$1" rp="$2" shape="$3" ref="$4"
    [[ "$shape" == "latest" ]] && ref="main"
    case "$rp" in
        *.md|*.ipynb) printf 'https://github.com/%s/blob/%s/%s\n' "$repo" "$ref" "$rp" ;;
        *)            printf 'https://github.com/%s/raw/%s/%s\n'  "$repo" "$ref" "$rp" ;;
    esac
}

# Does the remote have a `main` branch?
#   0  yes           1  no (branch genuinely absent)
#   2  indeterminate (ls-remote itself failed — transient transport/NFS error)
# CRUCIAL: the three cases must stay distinct. Conflating (2) with (1) — as the
# prior `ls-remote --exit-code ... || return 0` did — makes a transient
# ls-remote failure look like "empty repo, nothing to sync", so sync_tree skips
# the reset and leaves a STALE local HEAD in place. A later unchanged upload
# then pins that stale HEAD and emits a URL for a commit never on the remote
# (the dangling-SHA class, your-org/your-nexus#261). An indeterminate result
# must retry/fail, never silently short-circuit the sync.
remote_has_main() {
    local out rc
    out=$(_git_assets ls-remote --heads origin main 2>/dev/null); rc=$?
    (( rc == 0 )) || return 2
    [[ -n "$out" ]] && return 0 || return 1
}

# Bring the working tree to the remote tip; discards any orphaned local commits
# left by a dead prior manager. No-op (return 0) on an empty asset repo (no
# origin/main yet — the first-ever upload bootstraps it). Bounded
# retry-with-backoff absorbs transient NFS/asset-repo contention — the observed
# rc=3 on `fetch`/`reset --hard origin/main` under compute load
# (your-org/your-nexus#261) — instead of failing on the first hit.
#   0  synced (or remote has no main yet → bootstrap path)
#   1  could not sync after SYNC_RETRIES attempts (caller must fail loud)
sync_tree() {
    local attempt=0 backoff=1 hm
    while :; do
        remote_has_main; hm=$?
        if (( hm == 1 )); then
            return 0                      # no main on remote yet → nothing to sync
        elif (( hm == 0 )); then
            if _git_assets fetch --quiet origin main >&2 \
               && { _git_assets checkout --quiet main >&2 2>/dev/null || true; } \
               && _git_assets reset --hard --quiet origin/main >&2; then
                return 0
            fi
        fi
        # hm==2 (indeterminate ls-remote) or a fetch/reset failure → transient.
        attempt=$(( attempt + 1 ))
        if (( attempt >= SYNC_RETRIES )); then
            echo "upload-asset.sh: asset-repo sync failed after ${SYNC_RETRIES}" \
                 "attempts (transient NFS/remote contention?)" >&2
            return 1
        fi
        sleep "${backoff}.$(printf '%03d' "$(( RANDOM % 1000 ))")" 2>/dev/null || true
        backoff=$(( backoff * 2 )); (( backoff > 30 )) && backoff=30
    done
}

# --- 1. STAGE: publish this request (lock-free, atomic) --------------------
mkdir -p "$STAGING_DIR"
REQ_BASE="$(mktemp -u "$STAGING_DIR/req.XXXXXXXXXX")"
REQID="$(basename "$REQ_BASE")"
cp "$LOCAL" "$REQ_BASE.blob"
# Marker carries everything the manager needs; published via atomic rename so
# a half-written marker is never visible to a draining manager.
{
    printf 'repo_path\t%s\n' "$REPO_PATH"
    printf 'shape\t%s\n'     "$SHAPE"
    printf 'message\t%s\n'   "$MESSAGE"
} > "$REQ_BASE.req.tmp"
mv -f "$REQ_BASE.req.tmp" "$REQ_BASE.req"
RESULT="$REQ_BASE.url"

# --- 2. ELECT: block (bounded) for the manager lock ------------------------
exec {_LOCK_FD}>"$_LOCK" || { echo "upload-asset.sh: cannot open lock $_LOCK" >&2; exit 3; }
if ! flock -w "$LOCK_WAIT" "$_LOCK_FD"; then
    echo "upload-asset.sh: could not acquire upload lock within ${LOCK_WAIT}s" \
         "(a holder appears hung, OR a child leaked the lock fd — check" \
         "\`fuser -v $_LOCK\`; a git-credential daemon reparented to init is" \
         "the known culprit, your-org/nexus-code#468)." \
         "Request $REQID left staged in $STAGING_DIR." >&2
    exit 3
fi

# Re-mint the installation token NOW, under the lock. The token minted at
# startup is ~1 h TTL, but we may have blocked up to $LOCK_WAIT for the lock
# behind a long batch, and the drain below can itself run long. A token that
# expires between mint and push makes `git push` fail authentication — and,
# before GIT_TERMINAL_PROMPT=0, block forever on an unanswerable prompt while
# holding this lock (your-org/nexus-code#468). Mint late, push soon after.
if _fresh_token="$("$_script_dir/mint-token.sh")" && [[ -n "$_fresh_token" ]]; then
    TOKEN="$_fresh_token"
    ASSET_URL_AUTH="https://x-access-token:${TOKEN}@github.com/${REPO}.git"
else
    # Non-fatal: the startup token may still be valid. Fail at push, loudly.
    echo "upload-asset.sh: re-mint under lock failed; proceeding with the" \
         "startup token (it may have expired)" >&2
fi

# --- 3. DRAIN (manager, under lock) ----------------------------------------
# First-run bootstrap: clone the asset repo if this tree has no .git yet.
# Not _git_assets (no -C into a not-yet-existing dir) but the same hardening.
if [[ ! -d "$ASSETS_DIR/.git" ]]; then
    _git_hardened clone "$ASSET_URL_AUTH" "$ASSETS_DIR" >&2 \
        || { echo "asset-repo clone failed" >&2; exit 3; }
    # Empty asset repo → unborn HEAD on init.defaultBranch (often master);
    # pin to main so the first push lands on main (your-org/your-nexus#236 B8).
    if ! _git_assets rev-parse --verify -q HEAD >/dev/null 2>&1; then
        _git_assets symbolic-ref HEAD refs/heads/main
    fi
fi
_git_assets remote set-url origin "$ASSET_URL_AUTH" >/dev/null
sync_tree || { echo "asset-repo sync failed" >&2; exit 3; }

# Snapshot the batch: every complete marker present now (ours is guaranteed
# in the list). Retries re-commit this same fixed batch on a fresh base;
# markers that arrive later are handled by their own stager's election.
shopt -s nullglob
batch=( "$STAGING_DIR"/*.req )
shopt -u nullglob

declare -A _sha _rp _shape
processed=()
attempt=0
backoff=1
while :; do
    (( attempt > 0 )) && { sync_tree || { echo "asset-repo re-sync failed" >&2; exit 3; }; }
    processed=()
    made_commit=0
    for marker in "${batch[@]}"; do
        [[ -f "$marker" ]] || continue          # already drained by a prior manager
        reqid="$(basename "${marker%.req}")"
        rp=""; shp="pin"; msg=""
        while IFS=$'\t' read -r k v; do
            case "$k" in
                repo_path) rp="$v" ;;
                shape)     shp="$v" ;;
                message)   msg="$v" ;;
            esac
        done < "$marker"
        [[ -n "$rp" ]] || { echo "upload-asset.sh: marker $marker missing repo_path; skipping" >&2; continue; }
        blob="${marker%.req}.blob"
        dest="$ASSETS_DIR/$rp"
        mkdir -p "$(dirname "$dest")"
        # Basename-collision warning (your-org/your-nexus#236 B8): a distinct
        # source with the same basename overwrites at HEAD. Per-request commits
        # mean prior SHA-pinned URLs still resolve to their own content.
        if [[ -e "$dest" ]] && ! cmp -s "$blob" "$dest"; then
            echo "upload-asset.sh: WARNING: $rp already holds a different asset;" \
                 "overwriting at HEAD (prior SHA-pinned URLs still resolve)." \
                 "Pass --repo-path <unique> to keep both." >&2
        fi
        cp "$blob" "$dest"
        if _git_assets check-ignore -q -- "$rp"; then
            echo "upload-asset.sh: $rp matches a .gitignore rule in the asset" \
                 "repo; force-adding past it. The asset repo exists to host" \
                 "uploads — if a path shouldn't be uploaded, keep it under" \
                 "work/ rather than gitignoring it on the asset side." >&2
        fi
        _git_assets add -f -- "$rp" >&2
        if _git_assets diff --cached --quiet; then
            echo "upload-asset.sh: $rp unchanged; skipping commit" >&2
            _sha["$reqid"]="$(_git_assets rev-parse HEAD)"   # unchanged → pins existing HEAD
        else
            _git_assets commit --quiet \
                --author="${BOT_NAME} <${BOT_EMAIL}>" \
                -m "${msg:-Add asset via upload-asset.sh}" >&2 \
                || { echo "asset-repo commit failed" >&2; exit 3; }
            _sha["$reqid"]="$(_git_assets rev-parse HEAD)"
            made_commit=1
        fi
        _rp["$reqid"]="$rp"
        _shape["$reqid"]="$shp"
        processed+=("$reqid")
    done

    if (( made_commit == 0 )); then
        break        # nothing new to push; recorded SHAs already on the remote
    fi
    if _git_assets push --quiet origin main >&2; then
        break        # batch pushed
    fi
    attempt=$(( attempt + 1 ))
    if (( attempt >= PUSH_RETRIES )); then
        echo "asset-repo push failed after ${PUSH_RETRIES} attempts" \
             "(remote contention from another clone?)" >&2
        exit 3
    fi
    # bounded exponential backoff with jitter, then re-sync + retry
    sleep "${backoff}.$(printf '%03d' "$(( RANDOM % 1000 ))")" 2>/dev/null || true
    backoff=$(( backoff * 2 )); (( backoff > 30 )) && backoff=30
done

# --- VERIFY-BEFORE-RETURN: enforce the dangling-SHA invariant at runtime -----
# The staging model is *designed* so an emitted URL can only pin a pushed
# commit — but design-by-construction is argued, not enforced. Here we ASSERT
# it: authoritatively re-read the remote's `main` tip and confirm every SHA we
# are about to hand out is contained in it. This is the belt-and-suspenders
# that makes a dangling URL impossible even if a `git push` reported success
# without landing, a sync silently kept a stale HEAD, or the remote moved
# underfoot. A dead embed in a GitHub comment is strictly worse than a failed
# upload the caller can retry, so on ANY doubt we fail LOUD (exit 3) and emit
# NO URL. Markers are left intact (not yet cleared below) so the next election
# re-drains them — idempotent, no lost request.
if (( ${#processed[@]} > 0 )); then
    remote_has_main; _hm=$?
    if (( _hm != 0 )); then
        echo "upload-asset.sh: cannot verify push — remote 'main' unreadable" \
             "(rc=$_hm); refusing to emit a possibly-dangling URL" >&2
        exit 3
    fi
    if ! _git_assets fetch --quiet origin main >&2; then
        echo "upload-asset.sh: cannot verify push — fetch of origin/main failed;" \
             "refusing to emit a possibly-dangling URL" >&2
        exit 3
    fi
    _remote_tip="$(_git_assets rev-parse FETCH_HEAD)"
    for reqid in "${processed[@]}"; do
        if ! _git_assets merge-base --is-ancestor "${_sha[$reqid]}" "$_remote_tip" 2>/dev/null; then
            echo "upload-asset.sh: verify-before-return FAILED — SHA ${_sha[$reqid]}" \
                 "for ${_rp[$reqid]} is NOT on remote main ($_remote_tip); refusing" \
                 "to emit a dangling URL. Markers left staged for re-drain." >&2
            exit 3
        fi
    done
fi

# Push succeeded and every pinned SHA is verified on the remote: emit results
# and clear markers. A result URL can therefore never name an unpushed SHA.
for reqid in "${processed[@]}"; do
    url="$(build_url "$REPO" "${_rp[$reqid]}" "${_shape[$reqid]}" "${_sha[$reqid]}")"
    printf '%s\n' "$url" > "$STAGING_DIR/$reqid.url.tmp"
    mv -f "$STAGING_DIR/$reqid.url.tmp" "$STAGING_DIR/$reqid.url"
    rm -f "$STAGING_DIR/$reqid.req" "$STAGING_DIR/$reqid.blob"
done

# Strip the credential from the remote url, then release the lock so the next
# waiter can proceed immediately.
_git_assets remote set-url origin "$ASSET_URL_NOAUTH" >/dev/null
flock -u "$_LOCK_FD" 2>/dev/null || true

# --- 4. COLLECT this request's own result ----------------------------------
# Guaranteed present now: either we drained our own marker above, or a prior
# manager drained it before we acquired the lock and wrote our result then.
[[ -f "$RESULT" ]] || {
    echo "upload-asset.sh: internal error — no result for $REQID after drain" >&2
    exit 3
}
url="$(< "$RESULT")"
rm -f "$RESULT"
printf '%s\n' "$url"
