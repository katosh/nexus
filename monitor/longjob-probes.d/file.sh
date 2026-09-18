# shellcheck shell=bash
# monitor/longjob-probes.d/file.sh — longjob-watch subject probe: a file
# predicate. Contract: see slurm.sh.
#
# Target: a path. The predicate lives in the spec (`add file:<path> --when …`):
#
#   exists          done once the path exists (default)
#   grew            done once the file's size exceeds `.size0`, the size
#                   recorded at add time (0 when it did not exist yet)
#   match           done once `grep -E -- <pattern>` matches a line; the
#                   pattern is `.pattern` in the spec. A pattern that is a
#                   valid regex but matches nothing is `running`, forever,
#                   bounded only by the watch TTL — say what you mean.
#
# A file predicate has no failure state of its own: the thing that fails is
# the producer, which is a different subject. So `failed` is reserved for a
# predicate that cannot be evaluated (unreadable directory, bad regex), and
# an absent file under `grew`/`match` is `pending`, not `unknown` — absence
# IS the answer for a file, unlike for a job.

lj_probe_main() {
    local target="$1" spec="$2" when pattern size0 size
    when=$(printf '%s' "$spec" | jq -r '.when // "exists"' 2>/dev/null) || when=exists
    case "$when" in
        exists)
            if [[ -e "$target" ]]; then printf 'done|%s exists' "$target"
            else printf 'pending|%s absent' "$target"; fi ;;
        grew)
            size0=$(printf '%s' "$spec" | jq -r '.size0 // 0' 2>/dev/null) || size0=0
            [[ "$size0" =~ ^[0-9]+$ ]] || size0=0
            if [[ ! -e "$target" ]]; then printf 'pending|%s absent (size0=%s)' "$target" "$size0"; return 0; fi
            size=$(stat -c %s -- "$target" 2>/dev/null) || { printf 'failed|cannot stat %s' "$target"; return 0; }
            if (( size > size0 )); then printf 'done|%s grew %s → %s bytes' "$target" "$size0" "$size"
            else printf 'running|%s at %s bytes (waiting for > %s)' "$target" "$size" "$size0"; fi ;;
        match)
            pattern=$(printf '%s' "$spec" | jq -r '.pattern // empty' 2>/dev/null) || pattern=""
            [[ -n "$pattern" ]] || { printf 'failed|no pattern in spec for --when match'; return 0; }
            if [[ ! -e "$target" ]]; then printf 'pending|%s absent' "$target"; return 0; fi
            local hit rc
            hit=$(grep -E -m1 -- "$pattern" "$target" 2>/dev/null); rc=$?
            case "$rc" in
                0) printf 'done|%s matched /%s/: %s' "$target" "$pattern" "${hit:0:120}" ;;
                1) printf 'running|%s has no line matching /%s/ yet' "$target" "$pattern" ;;
                *) printf 'failed|grep rc=%s on %s (bad pattern or unreadable file)' "$rc" "$target" ;;
            esac ;;
        *)  printf 'failed|unknown file predicate %s' "$when" ;;
    esac
    return 0
}
