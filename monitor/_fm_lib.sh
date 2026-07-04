#!/usr/bin/env bash
# _fm_lib.sh — ONE keyed field reader (plus a writer available for adoption)
# for the two flat text schemas the nexus stores state in
# (your-org/nexus-code#405 P2). Before this lib, five bespoke parsers each
# re-derived the same idea (frontmatter `key: value`, bare `key=value`), and a
# tweak on one side silently regressed the other.
#
# Adoption status (be honest with yourself before editing):
#   READERS (`_fm_get`/`_kv_get`) — unified; these are the production read
#     path for frontmatter and bare-kv fields across the monitor.
#   WRITERS (`_fm_put`/`_kv_put`) — fully tested and available, but currently
#     have no production callers. The channel transition builders in
#     monitor/request-channel.sh (_build_reply_content & co.) intentionally
#     do NOT use `_fm_put`: each performs a coordinated whole-file atomic
#     transition (multi-line `reply:` block + `state:` flip + body append in
#     ONE rename) that a single-key put cannot express. Editing `_fm__put`
#     therefore does NOT change how the channel writes state — its parity
#     with the builders is held by monitor/watcher/test-fm-lib.sh.
#
# The two shapes:
#
#   FRONTMATTER (`_fm_get`/`_fm_put`) — a leading YAML-ish block fenced by two
#     `---` lines; fields are `key: value`, colon-separated, leading whitespace
#     after the colon trimmed (YAML convention). Reads/writes ONLY within the
#     fence; body content past the closing fence is never seen. Used by the
#     request/skeptic channels and the reply frontmatter.
#   BARE KV (`_kv_get`/`_kv_put`) — no fence; `key=value` records, one per line,
#     equals-separated, value byte-faithful (no whitespace trim). Used by the
#     enrollment token records.
#
# KEYS are identifiers by design and are VALIDATED against ^[A-Za-z0-9_-]+$ in
# both the readers and the writers (an out-of-charset or empty key fails with
# rc 2). This is honest enforcement of the invariant that lets a key ride an
# `awk -v` safely — an identifier carries no backslash to escape-process.
# VALUES are byte-faithful and are NEVER passed through `awk -v` (which would
# escape-process a literal `\n`/`\t`/`\\` and could inject a phantom field);
# the writer streams the value from a temp FILE via awk `getline`, which reads
# records raw. A value containing a real newline is rejected (rc 2): a
# single-line record cannot represent it, and silently splitting it would be
# exactly the field-injection this design forbids.
#
# Read semantics (both shapes): FIRST matching record wins; the value is the
# line remainder after the literal `key<sep>` prefix (frontmatter additionally
# strips the run of whitespace that follows the colon). The key is matched
# LITERALLY (byte prefix + separator), never as a regex, so a key that is a
# prefix of another (`state` vs `states:`, `expires` vs `expires_at=`) does not
# false-match. An absent key yields empty output and success.
#
# Write semantics (both shapes): update-in-place if the key exists (position and
# every other line preserved), else insert — frontmatter inserts just before the
# closing fence, bare kv appends at EOF. The whole file is rebuilt into a temp in
# the destination directory and `mv -f`'d into place, so a concurrent reader
# never observes a half-written file. A frontmatter put on a file that has no
# leading `---` fence (or on a missing file) creates the fence, preserving any
# existing content as the body. A frontmatter put on a file whose opening `---`
# fence is never CLOSED fails LOUDLY (rc 1 + stderr) rather than silently losing
# the write into a malformed file.
#
# Compat note vs. the parsers this replaced: the fence match here is lenient
# (`^---[[:space:]]*$`, i.e. a `---` line with optional trailing whitespace) and
# the field match requires only the `key:` prefix (zero-or-more spaces after the
# colon). The originals were a hair stricter on adversarial inputs the writers
# never emit — see monitor/watcher/test-fm-lib.sh "legacy parity" for the exact
# byte-for-byte equivalence proof on every real input and the enumerated,
# non-occurring edge divergences.
#
# Sourcing contract: defines functions only. The one intentional side effect is
# the `_FM_LIB` source guard below (so multiple libs may pull it in idempotently);
# beyond that it makes no `set` changes and touches no other global. Pure POSIX
# awk cores (the frontmatter reader is mirrored — semantically, specialized to
# the colon/fenced case — in the client's monitor/client/_nexus_watch_lib.sh so
# the confined POSIX-sh client stays self-contained); the shell wrappers use bash.

[[ -n "${_FM_LIB:-}" ]] && return 0
_FM_LIB=1

# Identifier-charset guard for keys (shared by readers + writers).
_fm__valid_key() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

# ---- read core ---------------------------------------------------------
# _fm__get <file> <key> <sep> <fenced>
#   sep    ':' (frontmatter) | '=' (bare kv)
#   fenced 1  (read only inside the leading --- fence) | 0 (read whole file)
# Prints the first match's value; empty (rc 0) if absent or file unreadable.
# rc 2 if <key> is not an identifier.
_fm__get() {
    local file="$1" key="$2" sep="$3" fenced="$4"
    _fm__valid_key "$key" || { printf '_fm__get: invalid key %q (need ^[A-Za-z0-9_-]+$)\n' "$key" >&2; return 2; }
    awk -v key="$key" -v sep="$sep" -v fenced="$fenced" '
        BEGIN { prefix = key sep; plen = length(prefix); infm = 0 }
        # Frontmatter: the opening fence is recognized ONLY on line 1 (a
        # trailing block of `---`s in the body is not a second frontmatter).
        fenced && NR==1 { if ($0 ~ /^---[[:space:]]*$/) infm = 1; next }
        fenced && infm && $0 ~ /^---[[:space:]]*$/ { exit }   # closing fence
        fenced && !infm { next }                              # outside the fence
        {
            if (substr($0, 1, plen) == prefix) {
                rest = substr($0, plen + 1)
                if (sep == ":") sub(/^[[:space:]]*/, "", rest)  # YAML value trim
                print rest
                exit
            }
        }
    ' "$file" 2>/dev/null
}

# _fm_get <file> <key> — first frontmatter `key: value` field, YAML-trimmed.
_fm_get() { _fm__get "$1" "$2" ':' 1; }
# _kv_get <file> <key> — first bare `key=value` record, byte-faithful value.
_kv_get() { _fm__get "$1" "$2" '=' 0; }

# ---- write core --------------------------------------------------------
# _fm__put <file> <key> <value> <sep> <fenced>  — atomic update-or-insert.
# The VALUE is streamed via a temp file + awk getline (never `awk -v`), so a
# literal backslash escape in it is written byte-faithful and cannot inject a
# field. rc 2 on an invalid key or a newline-bearing value; rc 1 on an
# unclosed-fence file or an I/O failure.
_fm__put() {
    local file="$1" key="$2" val="$3" sep="$4" fenced="$5"
    _fm__valid_key "$key" || { printf '_fm__put: invalid key %q (need ^[A-Za-z0-9_-]+$)\n' "$key" >&2; return 2; }
    if [[ "$val" == *$'\n'* ]]; then
        printf '_fm__put: value for key %q contains a newline; a single-line record cannot represent it\n' "$key" >&2
        return 2
    fi
    local dir tmp vf prefix rc
    dir=$(dirname -- "$file")
    tmp=$(mktemp "$dir/.fmput.XXXXXX") || return 1
    if [[ "$sep" == ":" ]]; then prefix="$key$sep "; else prefix="$key$sep"; fi

    if [[ "$fenced" == 1 ]]; then
        local firstline=""
        [[ -r "$file" ]] && IFS= read -r firstline < "$file"
        if [[ ! "$firstline" =~ ^---[[:space:]]*$ ]]; then
            # No leading fence (or missing file): create one, keep old body.
            # printf %s is byte-faithful for the value (no escape processing).
            { printf -- '---\n%s%s\n---\n' "$prefix" "$val"
              if [[ -r "$file" ]]; then cat -- "$file"; fi
            } > "$tmp" || { rm -f "$tmp"; return 1; }
            mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
            return 0
        fi
    fi

    vf=$(mktemp "${TMPDIR:-/tmp}/fmval.XXXXXX") || { rm -f "$tmp"; return 1; }
    printf '%s' "$val" > "$vf"
    # `prefix`, `key`/`sep` and `vf` (an mktemp path) are all charset-safe by
    # construction, so their `-v` carriage is escape-free; the value alone — the
    # only field that can carry backslashes — is read raw via getline.
    { if [[ -r "$file" ]]; then cat -- "$file"; fi; } | awk \
        -v prefix="$prefix" -v key="$key" -v sep="$sep" -v fenced="$fenced" -v vf="$vf" '
        function emit_repl(   v) {
            # exactly one record (the newline guard above forbids a multi-line
            # value); an empty value file yields getline 0 → an empty value.
            v = ""
            if ((getline v < vf) < 0) v = ""
            close(vf)
            print prefix v
        }
        BEGIN { m = key sep; mlen = length(m); infm = 0; done = 0 }
        fenced && NR==1 && $0 ~ /^---[[:space:]]*$/ { infm = 1; print; next }
        fenced && infm && $0 ~ /^---[[:space:]]*$/ {
            if (!done) { emit_repl(); done = 1 }   # insert before the closing fence
            infm = 0; print; next
        }
        fenced && infm && !done && substr($0, 1, mlen) == m {
            emit_repl(); done = 1; next            # update in place, order kept
        }
        !fenced && !done && substr($0, 1, mlen) == m {
            emit_repl(); done = 1; next
        }
        { print }
        END {
            if (!fenced && !done) emit_repl()       # kv: append if never matched
            else if (fenced && infm) exit 3         # opening fence never closed → malformed
        }
    ' > "$tmp"
    rc=$?
    rm -f "$vf"
    if (( rc != 0 )); then
        rm -f "$tmp"
        (( rc == 3 )) && printf '_fm__put: malformed frontmatter in %q (opening --- fence has no closing fence); refusing to write key %q\n' "$file" "$key" >&2
        return 1
    fi
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# _fm_put <file> <key> <value> — set a frontmatter `key: value` field.
_fm_put() { _fm__put "$1" "$2" "$3" ':' 1; }
# _kv_put <file> <key> <value> — set a bare `key=value` record.
_kv_put() { _fm__put "$1" "$2" "$3" '=' 0; }
