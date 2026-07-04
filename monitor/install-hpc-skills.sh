#!/usr/bin/env bash
# monitor/install-hpc-skills.sh — clone your-org/hpc-skills into a
# sandbox-writable location and link it under ~/.claude/skills/ so
# Claude Code's skill discovery finds it.
#
# Sandbox-correct paths:
#   target  = ~/.claude/hpc-skills           (clone)
#   symlink = ~/.claude/skills/hpc-skills    (umbrella sentinel)
#   per-sub-skill symlinks: ~/.claude/skills/<name> -> target/skills/<name>
#
# Reliability contract (see monitor/_install-lib.sh):
#   * Idempotent  — verify-and-repair: a complete install re-runs as a no-op;
#                   a partial one is completed. Missing per-sub-skill links are
#                   recreated; wrong ones repaired; dangling ones (renamed/
#                   removed upstream skills) pruned.
#   * Atomic      — clone-to-temp + rename (never a half-cloned target); links
#                   placed with `ln -snf`.
#   * Recoverable — leftover temp clones are cleared; a partial/corrupt/
#                   wrong-remote target is moved ASIDE (never destroyed) to
#                   <target>.broken.<ts> and re-cloned.
#   * Concurrency-safe — advisory flock on a local fs; two simultaneous
#                   bootstrap opens converge with no double-clone.
#   * Verified    — a final health gate asserts repo + symlinks are correct
#                   and FAILS LOUD otherwise (also exposed as `--check`).
#
# Fail-loud: git clone failure exits non-zero with the verbatim git error on
# stderr. URL is HTTPS so SSH-key-less bootstrap agents can clone.
#
# Flags: --check (verify only, no mutation, no lock; nonzero if incomplete)
#        -h|--help

set -uo pipefail

_self_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=monitor/_install-lib.sh
. "$_self_dir/_install-lib.sh"

die()  { printf 'install-hpc-skills: %s\n' "$*" >&2; exit 1; }
warn() { printf 'install-hpc-skills: WARNING: %s\n' "$*" >&2; }
stamp(){ date +%Y%m%d-%H%M%S 2>/dev/null || echo ts; }

REMOTE_URL="${HPC_SKILLS_REMOTE:-https://github.com/your-org/hpc-skills.git}"
REMOTE_ID="your-org/hpc-skills"

target="$HOME/.claude/hpc-skills"
skills_dir="$HOME/.claude/skills"
symlink="$skills_dir/hpc-skills"

CHECK_ONLY=0
while (( $# > 0 )); do
    case "$1" in
        --check)   CHECK_ONLY=1; shift ;;
        -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'; exit 0 ;;
        *) die "unknown flag: $1 (try --help)" ;;
    esac
done

repo_healthy() {
    install_dir_is_repo "$target" \
        && [ -d "$target/skills" ] \
        && install_remote_matches "$target" "$REMOTE_ID"
}

# ---- verification gate (read-only) ---------------------------------------
verify() {
    local fail=0 d name link dest expect=0 good=0
    if repo_healthy; then echo "  verify: clone OK ($target)"
    else echo "  verify: clone MISSING/BROKEN ($target)" >&2; fail=1; fi

    if [[ ! -L "$symlink" ]]; then echo "  verify: umbrella symlink missing ($symlink)" >&2; fail=1; fi

    for d in "$target/skills/"*/; do
        [[ -d "$d" ]] || continue
        expect=$(( expect + 1 )); name=$(basename "$d"); link="$skills_dir/$name"
        if [[ -L "$link" && -d "$link" ]]; then good=$(( good + 1 ))
        else echo "  verify: missing/invalid sub-skill link: $link" >&2; fail=1; fi
    done
    if (( expect == 0 )); then echo "  verify: no skills under $target/skills" >&2; fail=1
    elif (( fail == 0 )); then echo "  verify: sub-skill links OK ($good/$expect)"; fi

    for link in "$skills_dir/"*; do
        [[ -L "$link" ]] || continue
        dest=$(readlink "$link" 2>/dev/null || true)
        case "$dest" in
            "$target/skills/"*) [[ -e "$link" ]] || { echo "  verify: dangling sub-skill link: $link" >&2; fail=1; } ;;
        esac
    done
    return "$fail"
}

if (( CHECK_ONLY )); then
    verify || die "verification FAILED — run without --check to repair."
    echo "hpc-skills: verified."
    exit 0
fi

# ---- concurrency guard ----------------------------------------------------
install_acquire_lock hpc-skills || die "could not acquire install lock"

mkdir -p "$skills_dir" || die "could not create $skills_dir"

# ---- repo: recover + ensure (atomic) -------------------------------------
install_clean_temps "$target"

if ! repo_healthy; then
    if [[ -e "$target" ]]; then
        if install_dir_is_repo "$target" && ! install_remote_matches "$target" "$REMOTE_ID"; then
            die "refusing to overwrite $target — git repo with unexpected remote ($(git -C "$target" config --get remote.origin.url 2>/dev/null || echo none)). Move it aside and re-run."
        fi
        bak="${target}.broken.$(stamp)"
        warn "partial/incomplete clone at $target — moving aside to $bak"
        mv "$target" "$bak" || die "could not move aside $target"
    fi
    if ! install_atomic_clone "$REMOTE_URL" "$target"; then
        die "git clone failed; re-run manually or check network/auth"
    fi
    repo_healthy || die "post-clone verification failed at $target"
fi

# ---- symlinks: umbrella + per-sub-skill, verify-and-repair ---------------
# Claude Code's loader looks one level deep at ~/.claude/skills/<name>/SKILL.md;
# it does NOT recurse into umbrella dirs. So keep the umbrella symlink (sentinel
# + ad-hoc browsing) AND one symlink per sub-skill at the top level.
ln -snf "$target/skills" "$symlink" || die "could not symlink $target/skills → $symlink"

linked=0
for d in "$target/skills/"*/; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    sub="$skills_dir/$name"
    if [[ -e "$sub" && ! -L "$sub" ]]; then
        warn "$sub exists and is not a symlink; leaving alone"
        continue
    fi
    ln -snf "$d" "$sub" || die "could not symlink $d → $sub"
    linked=$(( linked + 1 ))
done

# Prune dangling links that point into OUR clone's skills/ (renamed/removed
# upstream). Untouched: real files and links pointing elsewhere.
pruned=0
for link in "$skills_dir/"*; do
    [[ -L "$link" ]] || continue
    dest=$(readlink "$link" 2>/dev/null || true)
    case "$dest" in
        "$target/skills/"*) [[ -e "$link" ]] || { rm -f "$link" && pruned=$(( pruned + 1 )); } ;;
    esac
done

# ---- final health gate ----------------------------------------------------
verify || die "install finished but verification FAILED — see warnings above."
echo "hpc-skills: installed at $symlink -> $target/skills (linked $linked sub-skills, pruned $pruned)"
