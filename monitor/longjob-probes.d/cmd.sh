# shellcheck shell=bash
# monitor/longjob-probes.d/cmd.sh — longjob-watch subject probe: an arbitrary
# command's exit status, re-run on every poll. Contract: see slurm.sh.
#
# Target: a shell command line, run as `bash -c "$target"` under the probe
# timeout the dispatcher applies to every kind. Its EXIT STATUS is the answer:
#
#   0        done      (the condition holds / the thing finished)
#   1        running   (not yet — keep polling)
#   2        failed
#   3        unknown   (the command could not tell; bounded-retry then emit)
#   124/137  unknown   (the probe TIMED OUT — a `timeout` wrapper's injected
#                       status, never a verdict of the command itself,
#                       your-org/nexus-code#1248)
#   other    failed    (the default arm EMITS; an rc outside the vocabulary
#                       is not assumed transient)
#
# The last line of stdout (≤ 200 bytes) is carried as the detail.
#
# This is also the "second tenant" contract from your-org/your-nexus#375: a
# LEVEL-TRIGGERED tick such as `monitor/watcher-supervise-tick.sh`, whose own
# convention is `exit 0` alive / `exit 1` down, is expressed by remapping its
# rc into this vocabulary:
#     add cmd:'monitor/watcher-supervise-tick.sh; case $? in 0) exit 1;; *) exit 2;; esac' --persistent --interval 60
# which maps alive → running and down → failed. With `--persistent` the
# dispatcher emits on EVERY transition (running→failed, failed→running) and
# never retires the watch, so the detector survives its own fire — the
# property the skeptic's S1 finding requires (a plugin-monitor command that
# exits is never relaunched).

lj_probe_main() {
    local target="$1" out rc last
    out=$(bash -c "$target" 2>&1); rc=$?
    last="${out##*$'\n'}"; last="${last:0:200}"
    case "$rc" in
        0)       printf 'done|rc=0 %s' "$last" ;;
        1)       printf 'running|rc=1 %s' "$last" ;;
        2)       printf 'failed|rc=2 %s' "$last" ;;
        3)       printf 'unknown|rc=3 %s' "$last" ;;
        124|137) printf 'unknown|probe timed out (rc=%s is the timeout wrapper'"'"'s, not the command'"'"'s) %s' "$rc" "$last" ;;
        *)       printf 'failed|rc=%s (outside the 0/1/2/3 vocabulary — emitted rather than assumed transient) %s' "$rc" "$last" ;;
    esac
    return 0
}
