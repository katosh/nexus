# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project does not yet have tagged releases — entries
accumulate under `[Unreleased]`. See
[`docs/contributing/release.md`](docs/contributing/release.md)
for the current release convention.

## [Unreleased]

### Changed — cc-auto-update deployment gate: the board arms are gone; the board is recorded, not gated on (w239 D13)

`monitor/cc-auto-update-apply.sh` `_deployment_gate` no longer defers on the
live-window COUNT (`max_live_windows`), on a window that does not positively
assert it is dead (board-not-quiet, `#1113`), or on a board it cannot
enumerate. Operator decision, 2026-09-12: *"a cc-update will not kill the
worker, and if they, for whatever reason, would crash, then the orchestrator
can continue them with no context lost."* The premise was measured before the
arms went, at `8d0cff30`: every kill primitive on the restart path enumerated
(the watcher is reaped by process group behind an argv-identity check that
refuses a group with no watcher member — rc 2 against a worker pane's own pgid;
the orchestrator is killed by window name after an exact-name index resolution
and a baseline pane-pid re-read); `restart-orchestrator` and
`launcher.sh --replace` driven on a private tmux with worker windows alive,
every worker keeping its window id, pane pid and child; `spawn-worker.sh
--resume <sid>` driven end-to-end against an argv-recording stub. Not proved
and not claimed: that Claude Code restores the conversation on `--resume`.
The two PR arms (restart-path PR, PR-under-active-review) and their cap-3
bounded deferral are unchanged. The board is still enumerated and written to
every apply record (`live_windows=`, `unquiet_windows=[…]`, new
`board_probe=`); an unenumerable board records `live_windows=UNMEASURED` and
files a defect instead of deferring. `monitor.cc_auto_update.max_live_windows`
/ `CC_AUTO_MAX_LIVE_WINDOWS` are no longer read (commented out in the example
config). One residual named rather than fixed: tmux 2.6 resolves
`kill-window -t <name>` by PREFIX when no exact-named window exists (measured:
with `orchestrator` gone it killed `orchestrator-sk`); the apply path is
guarded twice, and ID-targeting the kill is the follow-up. Also corrects the
header's "#503 decapitated 15 agents": #503 decapitated the WATCHER while 15
agents were mid-flight; no agent was killed. `test-cc-auto-update.sh` cases
G3, G2b, Q1, Q2, Q4–Q6, Q9c, Q10, P1, P2, O2, O3 and the #1438 gate cases are
flipped or re-based onto the PR arms; each flipped case fails on the pre-change
tree.

### Fixed — `#1497`: assert-shims-wrapped's probe shells run DETACHED from the tty and KILLABLE

`monitor/assert-shims-wrapped.sh` ran its login+interactive probe as a bare
`timeout 40 $SHELL -lic …`. Inside a tmux pane — where every launcher runs the
guard — GNU `timeout` puts that interactive shell in a background process group
of the pane's tty, job control stops it before the `-c` command runs, the
SIGTERM at 40 s is ignored by an initialised interactive shell, and with no `-k`
the guard waits forever. Measured 2026-09-06/08 (zsh 5.4.2, bash 4.4, coreutils
8.28): two orchestrator boots of one nexus hung there (`pane-state` reading
`unknown reason=live-descendant`, every emit `FAILED rc=4`); on the other runs
the same probe cost 43 s and came back EMPTY, a guard blind on the surface it
exists to check. Both probes now go through `_asw_probe_exec` =
`setsid -w timeout -k 5 40 … </dev/null` — `setsid` outside so the shell has no
controlling tty (the footing Claude Code's own snapshot subprocess has),
`timeout` inside so its group-kill reaches descendants the shell spawned before
wedging. `NEXUS_ASSERT_PROBE_TIMEOUT` / `NEXUS_ASSERT_PROBE_KILL_GRACE` expose
the two numbers for tests. `test-assert-shims-wrapped.sh` case 13 pins it: a pty
positive control, the probe shell observing NO controlling tty under that pty,
and a SIGTERM-ignoring probe killed at timeout+grace; against the unpatched
guard the last two arms fail.

### Added — `#1490`: `tee /dev/stderr` REOPENS fd 2 and truncates the log — the construct is now linted repo-wide

`tee` OPENS its file argument. `/dev/stderr` is a PATH to whatever fd 2 points
at, and an open of a regular file TRUNCATES it, so a service launched
`>>"$log" 2>&1` loses its entire history on the FIRST line it emits — rc 0,
nothing on stderr. Measured: a seeded 40-line log came back as **1 line**.
`tmpfs-guard` was the host, and it is the worst possible one: a guard whose
job is to describe an ACCUMULATING condition, destroying its own evidence on
every finding. Both its sites now go through a new `emit_both`, which writes to
fd 1 and `>&2` — a DUP, never an open.

**The axis is wider than the issue's title, and it was measured rather than
reasoned.** `tee /dev/fd/2` truncates identically, and so does a plain
`> /dev/stderr` REDIRECT with no `tee` anywhere; `>>`, `tee -a` and `>&2` do
not. A lint keyed on `tee` would have certified the redirect form clean, so
`monitor/watcher/tee-reopen-lint.sh` keys on REOPENING BY PATH.
`test-tee-reopen-lint.sh` drives both directions over planted fixtures and
declares its population at birth.

The lint's own first draft was a **silent zero**, and it is pinned as a case:
run against a fixture lacking `_shell_quotes.awk`, `shf_strip_comments` REFUSED
correctly and loudly, the diagnostic went to a `2>/dev/null`, the stripped text
was empty, and the lint reported a clean sweep over a tree holding two known
violations. The refusal was never lost — it was merely off the path that
produced the answer, which is all a silent zero needs.

### Changed — `#1501`: `mint-token.sh` now REFUSES an exposed bot key (exit 4) — and deliberately does NOT refuse a merely loose mode

The script checked `-f` and `-r` only, while the words *"should be 600"* sat in
the unreadable-key FAILURE MESSAGE and two documents asserted it rejects a
loose key mode. A documented guarantee with no enforcing branch is worse than a
documented gap: a gap invites scrutiny, a false guarantee deflects it.

**What is enforced is narrower than `mode == 600`, and that is the point.** A
file mode is the LAST gate, not the only one: the issue was filed as an
exposure on `stat` of the FILE (644) and withdrawn once the ancestors were read
— `~/.claude` is 700, traversal denied, the bits inert. So the gate walks the
ancestors and refuses only on a POSITIVELY ESTABLISHED exposure (world bits AND
an unbroken world-traversable path). Group access is reported, never acted on;
an ancestor it cannot `stat` is `unknown`, which is neither. `--check-key`
prints the full verdict without minting (0 ok, 4 exposed, 5 tolerated-but-worth-
seeing). The anti-false-refusal control is pinned as hard as the refusal:
`mint-token.sh` is on the path of every GitHub write here, so refusing an
airtight setup would be a self-inflicted outage in answer to a non-problem.

**FIVE documents now describe what the code does, not the two the issue named.**
A sweep for docs CLAIMING an enforcement cannot see a doc asserting its
ABSENCE, and there were three of those — `monitor/install-prompt.md`,
`monitor/BOT_SETUP.md` and `monitor/BOT_ADMIN_GUIDE.md`, the last two found
only by re-sweeping for the INVERSE wording (*"does not enforce"*, *"happily
sign"*, *"nothing warns you"*). **After a behaviour change the stale docs sit on
BOTH sides of it**, and the side you did not search for is the side you miss.

### Fixed — `#1495`: the disposition DEADLOCK — a settled `require` gate refused both dispositions

`_disposition_gate_conflict`'s `require` arm read the SPAWN RECORD alone and
treated it as a permanent present-tense obligation, so a window whose required
pass had HAPPENED and been settled could state NEITHER value: `second-pass`
refused by `retire-preflight` 1c, `no-further-pass` refused here. Reachable
only after everything went right. The arm is now resolution-aware, exactly as
the marker arm beside it already was — a spawn-time property is evidence about
what was DEMANDED, never about what is OUTSTANDING — and only a positive
`resolved` releases (`none`, `re-armed` and `unknown` still conflict).

The refusal also **names the ledger and prints the outstanding arm's sha**. The
settlement discharges the worker's own report AS IT STOOD AT ARMING TIME, that
sha lives in exactly one place, and the append-only convention keeps the
report's current sha moving — so a worker that had followed every convention
could not derive the citation from anything it held, and the refusal named the
ledger zero times. The one instance on record was solved by reading the ledger
on a hunch.

### Fixed — `#1491`: `ng wrap-up` verifies the comment target BEFORE it arms anything

A wrap-up passed `--repo <asset-repo>`; that flag selects the ISSUE-THREAD
target, the issue lived elsewhere, the comment POST 404'd — and the run had
ALREADY released the skeptic marker and went on to write a ledger entry. The
thread was never told. `wrap-up` now asks whether the target repo contains the
issue before Step 0b, and refuses naming the flag that was mis-read. Three-
valued: only a POSITIVE 404 refuses; a probe that fails for any other reason
warns and proceeds, because a failure to LOOK is not a finding and blocking a
hand-off on an unanswered question is the more expensive error.

Restores the companion rule from `#1050`: order any two-part operation so the
failure mode is the OBSERVABLE one.

### Changed — `#1494`: three guards enrolled — including both that CI reddened on while the index could not see them

On PR `#1493`, `guards-for-diff` returned rc 0 with 28 guards SELECTED and
green; CI then reddened on two suites, and NEITHER appeared in `SELECTED` or in
`CONSIDERED AND EXCLUDED`. A suite that declares no population is INVISIBLE,
not excluded, and the two are indistinguishable in the output while meaning
opposite things. `test-count-fallback-lint.sh`, `test-tmux-shim-gate3-safety.sh`
(a SAFETY guard whose failure mode is a client reaching the operator's real
tmux board) and `test-cc-auto-update.sh` (the largest suite exercising that
diff's own subject) now declare. `count-fallback-lint.sh` grew a `--files`
mode so the declaration forwards to the lint's own selection rather than
copying it. Declaring 75 → 79; the census `unreviewed-ceiling` 394 → 391.

**NOT `#1301` item 2, and the distinction is the point.** That item named three
DIFFERENT suites — `test-argloop-progress-guard.sh`, `test-shell-files.sh`,
`test-skeptic-evidence-class-agreement.sh` — enrolled by `f77f18d8` on
2026-09-02, a week before this bundle and an ANCESTOR of its base. Verified:
`git merge-base --is-ancestor f77f18d8 1fadbc67` → yes, and all three already
declare at `1fadbc67`. The three enrolled HERE were `decl=0 pop=0` at that same
base, so the WORK is this bundle's and the ISSUE LABEL was not. A fix is a
property of a tree in the same way a count is.

`#1301` item 1 — a per-diff NAMED blind spot — is untouched and stays open:
there is still no readership approximation whose direction of error anyone can
state, and the obvious proxy fails on `#1171`, the case that motivated it.

### Added — `#1483`: the last two `none` positive-control rows are now plants; `none-ceiling` 2 → 0

`test-spawn-shape-manifest.sh` plants a spawn call site absent from the manifest
in a scratch git repo and asserts the `UNCLASSIFIED` arm fires;
`test-skeptic-evidence-class-agreement.sh` deletes one evidence class from ONE
of the two `retire-preflight` arms in a copy and asserts the membership
comparison names it. Both assert on the MESSAGE rather than the exit code — a
small fixture also trips other arms, so rc 1 alone would be satisfied by a
suite whose red arm had been deleted — and both carry a NEGATIVE arm (an
unmodified copy through the same override) so "caught the plant" is
distinguishable from "reddens on any copy". The spawn-shape control's fixture
text is itself a spawn call site, so it is classified in
`spawn-shapes.manifest` rather than exempted by name.


### Changed — `#1264` R4 / `#1474`: a `none` positive-control row must be OWNED; the CI log tail proves nothing

`test-guard-positive-controls.sh` now reds a `none` row whose reason carries
neither a tracker ref (`#NNN`) nor an `until:YYYY-MM-DD` expiry — an unowned
exemption is inherited rather than re-justified (`#1469`). The one such row,
`test-spawn-shape-manifest.sh`, now points at `#1483`. `ci-band-coverage.sh`
states in its header and its `complete` output that the verdict SET, not the
log tail, is the evidence: measured on `#1482`'s own cancelled band, a mid-run
kill missing 22 suites ended with the same cleanup lines as a teardown kill.

### Added — `#1264` R4/R5: every guard declares its positive control; every enumeration feeding a decision is a set-equality ratchet — with their sweeps

`guard-positive-controls.manifest` + `test-guard-positive-controls.sh`: one row
per declaring guard (70 at the census, 74 with this PR's own suites), the
verbatim assertion label of the planted violation it catches, set equality both
ways against `guard-populations.manifest`, a `none-ceiling` ratchet (1:
`test-spawn-shape-manifest.sh` has no plant). `test-skills-catalog.sh`: the
skills catalog is checked against the shipped `skills/*/` directories both ways
(it was missing `nexus.ci-triage` and `nexus.claims`; fixed).
`suite-declarations.manifest` + `test-suite-declaration-census.sh` (`#1301`
item 3): every tracked suite either declares a population or has an explicit
row — 394 `unreviewed` at the census, a ceiling that only goes down; a new suite
can no longer land silently in the index's blind spot.

### Added — `#1474`: `monitor/ci-band-coverage.sh` tells a cosmetic ceiling kill from a coverage gap

A cancelled unit band renders `fail` either way; the tool compares the SET of
suites carrying a verdict in the job log against the population discovered at
the head (two sources, refused when they disagree) and reports `complete`
(teardown kill, cosmetic), `mid-run-kill` (members named) or `incomplete`.
Measured on this bundle's own PRs: #1479 zsh 13 suites never reached; #1480
bash 447 of 447 verdicted. Set membership, never a count.

### Added — `#904`: a size budget for `## Common gotchas` entries in `CLAUDE.md`

`test-claude-md-entry-budget.sh` prints every entry's size on every run and reds
only past the generous ceilings in `claude-md-entry-budget.manifest` (120 lines
per entry, 40 entries; census max 104 / 31). The remedy for a red is a skill
plus a one-line row, not shorter prose.

### Fixed — `#1477`: the frozen-snapshot leg of `assert-shims-wrapped.sh` refused every spawn for 18 h on a FOREIGN snapshot, and could refuse `_respawn.sh` (PR 1479)

Self-heal is a hard invariant on that leg: with `NEXUS_IS_ORCHESTRATOR=1` a
BURIAL is a warning plus a durable `guard-unverified.log` row, never a refusal.
A snapshot with NO shim dir anywhere in its PATH while the live probes are clean
is FOREIGN (written by a `claude` launched outside the nexus) and warns; the same
with the probes not run is NOT CHECKED (79). `spawn-worker.sh` carries the
spawning agent's own snapshot into the launcher (`NEXUS_SPAWNER_SNAPSHOT`), which
the guard ranks above the mtime proxy and reports. The suite gained a
NON-HERMETIC arm over the real host's newest snapshot (SKIP counted where there
is no CC home). GUIDE Divergence 5 rewritten: never launch `claude` by hand from
a plain shell in a nexus.

### Changed — cc-update: clone freshness is never a verdict input (PR 1480)

Operator directive on `<your-org>/nexus-code#1475`: the LOCAL gate decides; a local
GREEN bumps however far behind `origin/dev` the clone is, and a local RED blocks
on the local classifier — a fresh-tip control changes the remedy named, never the
verdict. Pinned in `test-cc-auto-update.sh` on the `safe-bumped` row.

### Fixed — `#1471`: `spawn-worker.sh --dry-run` without `--resume` spawned a REAL worker

Refused (exit 22) before anything is composed; an unrecognised `--` option is
refused (exit 23) instead of passed through. Asserted on the side effect: a
stub-tmux spawn attempt leaves no `new-window`.

### Fixed — `#1478`: the `N awaiting-input` prelude scalar counted the orchestrator's own `idle_prompt`

Excluded by the watcher's paste-target identity (`$TARGET`, default
`orchestrator`), in both the jq and the awk arm. And `STATE_DIR` unset no longer
resolves any `_idle_probe.sh` state path to the current directory — the four
stray state files found at the operator's repo root shared one mtime — but to an
announced per-user scratch fallback.

### Added — `#1423`: a healthcheck can say "I am UP and the condition I watch is PRESENT" (exit 100)

`_service_health.sh` treats exit 100 as a FINDING: no incident, no grace, no
restart; the emit says "is UP and reports a FINDING", carries the check's stderr,
re-surfaces only when the text changes, clears itself when the check goes green,
and never offers `svc.sh restart`. `tmpfs-guard.sh --check` exits 100 on a
threshold breach (3 stays "could not measure"); `bootstrap-recover.sh` treats 100
as not-down. Documented in `services.registry.example`.

### Fixed — `#1423` / `#1474`: the test harness leaked two zero-byte files per process into `/tmp`

`_test_helpers.sh` reaps its own `.th-ledger.*` / `.th-ports.*` on EXIT when the
suite installs no trap (`th_trap_exit` chains for suites that do), and
`run-tests.sh` gives every suite ONE short private root (`/tmp/nxt-<uid>-…`)
as both `TMPDIR` and `TMUX_TMPDIR`, reaped when the suite exits. Measured live
before the fix: 37,727 ledgers and 21,537 ports files. The first cut rooted the
private dir under the log directory and reddened all six CI bands (`#1481`):
tmux fixtures blew the 108-byte `sun_path`, one suite asserted its fixture is
under `/tmp`, one capped a diagnostic at 300 B — a suite's assumptions about
`$TMPDIR` are part of the harness contract. `nx_tmux_fixture_init` no longer
derives its socket dir from the caller's workdir at all.

### Changed — `#1448`: `cc-auto-update-apply.sh safe` REQUIRES the gate log's geometry stamp

Evidence without a `=== gated-tui:` line is refused on the bump path
(`gated-tui-stamp-missing`), the way the tree stamp is; the attribution note
records `tui=<mode>`. Previously the field was additive and unstamped evidence
was accepted unremarked.

### Fixed — `#1334`: a worker could boot into the workspace-trust dialog with the seed present, and nothing recovered it

**Two layers, and the primary is a single environment variable.** Every
launcher `spawn-worker.sh` generates now sets `CLAUDE_CODE_SANDBOXED=1` on the
claude invocation. Measured on the real 2.1.261 binary: the flag is read at the
head of the trust gate and returns "trusted" before
`projects.<cwd>.hasTrustDialogAccepted` is consulted, so the dialog cannot
appear whatever happened to the seed. It is a claim about the environment, and
it is TRUE here — workers run under a kernel-enforced sandbox — so setting it
informs the tool rather than defeating a check. Its marginal effect was
measured with the real worker configuration (`--dangerously-skip-permissions`
+ `worker-settings.json`), one variable at a time: the trust gate moved and
nothing else did — print-mode project-permission-rule gating was unchanged
by the flag in both directions (that path keys on the config key itself),
the `/cd` move dialog and post-move pane were byte-identical, and the normal
boot frame was byte-identical. Because it is undocumented and read at three
sites in a binary re-pinned weekly, a real-binary CANARY
(`test-integration/test-realmodel-trust-sandboxed-env.sh`, gated) pins its
semantics: key absent + flag → idle; key absent alone → the dialog. Belongs on
`skills/nexus.cc-update/GUIDE.md`'s collision list.

**The fallback is a bounded detect-and-recover loop after the launcher is
sent, at BOTH window-creation sites** (fresh and `--resume`). It polls
`pane-state.sh` to the first positive state (~1–3 s on the normal path);
`empty` is tolerated to `NEXUS_SPAWN_TRUST_VERIFY_SECONDS` (default 20) and
then reported UNVERIFIED at exit 0 — never a manufactured failure. On the
exact pair `state=blocked overlay=workspace-trust` it reads the key from disk
BEFORE acting and prints AND action-logs `trust-key-at-detection=…` — the
discriminating measurement the issue prescribed, now taken automatically on
every field occurrence — then kills the window, re-seeds through
`ensure-workdir-trusted.sh`, READS THE KEY BACK, re-creates the window under
the same name (anchors and provenance are name-keyed) and re-sends the kept
launcher; `--session-id` reuse after a kill at the dialog was measured safe
(no transcript exists yet). Bounded at `NEXUS_SPAWN_TRUST_MAX_RECOVER`
(default 2), then **exit 21** with a diagnostic and the window left in place.

**The kill is a stated exemption from `bk_pane_kill_authorized`, not a
weakening of it.** `blocked` stays off the allowlist and `_bookkeeping.sh` is
untouched. The kill fires only on that exact overlay pair, and only after a
no-work-lost precondition asserted immediately before it: zero transcript for
the session id (fresh), the resumed transcript's size+mtime unchanged since
the launcher was sent (`--resume`), or no transcript under the workdir's
project slug newer than a pre-send stamp (loop wrapper). A transcript that
exists or moved means something ran, the detection is wrong, and recovery is
REFUSED at exit 21. The unit suite drives every arm, including that refusal;
two code mutants (predicate disabled, precondition disabled) flipped exactly
the predicted 27 and 5 assertions.

**The precondition's probes use `find -H`, and the loop-wrapper arm is coarse
on purpose — which makes that arm largely INERT on a busy board.** As first
pushed, the fresh-path probe was a confident zero on this host: the config
dir's `projects` is a SYMLINK and GNU `find` does not descend a symlinked
starting point, so the check passed for a transcript that existed (found by the
skeptic pass; measured bare `0`, `-H` `1` against a real transcript). Every
probe now uses `-H`, and the fixture asserts the symlink shape in BOTH
directions. The loop-wrapper arm no longer re-implements the binary's
undocumented project-slug encoding (a wrong slug failed OPEN); it refuses on ANY
transcript under `projects/*/` newer than the pre-send stamp. State the
consequence plainly rather than counting the loop as coverage it does not
provide: **the wrapper path's recovery is ACTIVITY-DEPENDENT — it refuses
whenever a sibling transcript happens to be written inside the stamp window,
a function of what other windows are doing at that instant, not of how many
exist. Measured by the skeptic on the live board: 5 live windows, stamps at
3/10/20 s, 0 of 3 windows had any transcript newer than the stamp, with 7
transcripts touched in the prior hour — so an earlier "usually refuses" was
wrong and is withdrawn. When it does refuse it fails to a VISIBLE dead worker
(the dialog stays on screen, `state=blocked overlay=workspace-trust`, exit 21)
rather than to a silent kill, and the PRIMARY mechanism for that path is the
launcher flag, not the loop.** The wrapper is opt-in and off by default. A
refused recovery costs one spawn; a wrong kill costs a worker's session.

**A hypothesis retired.** The issue's surviving explanation — claude rewrites
`.claude.json` wholesale from stale memory — is NOT supported: with a claude
sitting at the dialog, keys seeded externally for other directories survived
its dialog-accept write, its graceful-exit write and a fresh-startup write,
and the file's inode changed on every write (temp+rename). The residual that
cannot be excluded that way is a narrow read-modify-write interleave claude
takes no lock against; the loop is correct under either.

### Fixed — `#1207`: the armed state had a second writer that could not name a subject

Builds directly on the `#1199`/`#1191`/`#1190` work in this same section and
closes the hole it documented rather than repaired.

**The root cause.** The armed state has TWO writers: `ng wrap-up
--skeptic-decision require` wrote the marker AND an `armed` ledger row, while
`spawn-worker.sh --skeptic-role` wrote the marker ALONE. `spawn-worker`'s own
comment says it is "the ONLY thing that restores the block" for a
second-or-later pass — so every re-validation round, the rounds that exist
*because* something was already found wrong, armed with nothing the ledger could
credit. Measured on the live board: `annz36` logged `subject-armed-sha:"-"` at
verdict time with no `skeptic-request` event at all, and `.ncpanestate.ledger`
carries ONE `armed` row against FOUR rounds of review, so all six delivered
verdicts read `asserted-not-armed` — the arm never moved while the report was
amended under it. A new `ng skeptic-arm` verb owns the row format and
`spawn-worker.sh` now records the arm against `PRIOR_REPORT_RESOLVED`, the report
the reviewer is actually pointed at. The append is skipped when the artefact is
already outstanding: a second arm for one artefact IS
`ambiguous-N-arms-outstanding`, so an unconditional append would trade pole A of
`#1156` for pole B.

**A verdict on a key with NO ledger is now recorded too, reversing a control
pinned by the `#1191` fix.** That fix recorded the `no-open-arm` shape (a ledger
exists, nothing outstanding) and deliberately kept dropping the no-ledger shape,
reasoning that "`spawn-worker.sh` re-establishes markers without a subject, and a
`-` row on a key nothing ever armed would assert a verdict about a window with no
history". That premise IS the `#1207` mechanism, now removed at the source. And
the row asserts something narrower than the premise allows: not that the key was
armed, but that A VERDICT WAS DELIVERED — true, since
`_skeptic_record_discharge` is reached only from the wrap-up verdict path.
Dropping it made the key report `evidence=none`, documented as "a POSITIVE claim
(nothing has ever settled this key)", whose instruction is *get a review* — for
work a reviewer already finished. The row carries subject `-`, so the inertness
argument already asserted for the `no-open-arm` row holds identically: it can
close no arm and authorise no suppression. New class `verdict-without-arm`, kept
distinct from `no-open-arm` because the causes and the remedies differ.

**`superseded=0` where the question does not apply.** `sup_state` is computed
only when a cleanly-matched row exists, so an all-unmatched ledger falls through
to `0`, glossed "the attributed row is fine" with `attributed_verdict=-` on the
same line. 19 of 64 live ledgers print that pair; 14 carry a delivered verdict.
The value stays `0`; `superseded_why=no-attributed-row-to-supersede` carries the
honesty. Orthogonal to `standing_stale`.

**`ng obligation settle` cannot release a counterpart in `await`.**
`skeptic-channel.sh close` is the sole writer of the `DONE` sentinel and
`obligations.sh` writes nothing under `skeptic/<task>/`. `settle` now says so at
settle time, complementing the `retire-preflight` await clause.

### Fixed — two refusal paths that told the operator the opposite of the truth

**`_sk_ev_explain`'s default arm was DEAD, so delivered classes went unexplained.**
It was a five-class allowlist with `*) [[ -n "$_SK_EV_SUPERSEDED" ]] || return 0`.
`_sk_ev_load` normalises `_SK_EV_SUPERSEDED` to the empty string for every value
except `1` and a qualifying `?`, so the escape almost never fired and any class
outside the five names was SILENT — a false NEGATIVE. Measured as stderr bytes,
driving `_sk_ev_explain` against planted ledgers, base `7151a13` vs head:
`no-open-arm` 0 → 917, `unmatched-other` 0 → 832,
`prior-verdict-other-artefact` 0 → 835, with a control class already in the
allowlist printing on both trees. `no-open-arm` is the sharp one — added to the
classifier and to the sides authority by the change that introduced it, and never
reaching this arm, so a verdict of that class was delivered, recorded, and
explained to nobody. Now an allowlist with a default-DENY.

*Correction:* an earlier revision of this entry claimed the opposite — that the
arm fired on EVERY class and printed "A VERDICT IS ON THE RECORD … evidence=none"
on an armed-only ledger — and quoted output for it. **That does not reproduce**:
measured silent (0 bytes) on `dev` 50c36ef, on base `7151a13` and on head. The
figure came from a probe that hand-set `_SK_EV_SUPERSEDED="0"`, a state
normalisation never produces, and was written up as a live measurement. The code
change is unaffected; only its justification was wrong.

**The "ONE AUTHORITY" for evidence classes reached one of its four consumers.**
`_skeptic_evidence_sides` is read by `monitor/ng` and its own suite;
`retire-preflight.sh`'s two `case` arms hand-maintain copies and both were
missing `unmatched-other` and `prior-verdict-other-artefact` — and `no-open-arm`
was added to the classifier and to the authority without reaching either. Both
arms have a permissive default, so for those classes the operator was told to
"discharge with a verdict or settle" with no mention that the creditor's ledger
already records one. Lists reconciled, and
`monitor/watcher/test-skeptic-evidence-class-agreement.sh` now checks the
four-way agreement as SET EQUALITY.

Also removes a shadowed duplicate `_skeptic_artefact_sha` in `monitor/ng` — two
byte-identical definitions, only the second ever ran — and guards against the
class returning.

### Fixed — the vacuous-evidence cluster: four checks that reported success while having examined nothing (`#1145`, `#1121`, `#1119`, `#1130`)

**`#1145` — two suites were tallied PASS after ZERO checks.** `#568 A6` added the
runner's third state and fixed the RUNNER; `test-public-guard-refusal.sh` and
`test-integration/test-jupyter-service-real.sh` never adopted the CONVENTION that
state depends on, so the hole stayed open for months exactly where the runner's
header says it was closed — named by the census on every run, and green every
time. `exit 0` -> `exit 77`, and the `ALL TESTS PASSED (0 checks …)` banner is
DELETED rather than reworded, because that string is what humans and scrapers
grep for. **The population question is answered on the LEDGER** (`status=PASS`
with `assertions=0`), which is a property rather than a spelling: **0** vacuous
passes across the fast band (376 selected, 352 PASS / 23 SKIP) and **0** across
`SLOW_TESTS=1` (375 selected, 354 PASS / 16 SKIP), with two planted controls —
one printing a zero-check banner, one with no footer at all — proving the census
names both shapes. **And the census is now RED rather than merely printed:**
`run-tests.sh` exits 1 on a non-empty zero-assertion list. No suppression knob;
the fix is one character in the declining suite.

**`#1121` — the allowlist doctrine's THIRD property**, in `CLAUDE.md` and executed
by `test-claude-md-arm-order-shadowing.sh`: *no SAFE arm may precede a DENY arm
that could fire on the same input*. The pair the doctrine was always stated as —
allowlist, default-deny — was satisfied EXACTLY by a classifier that pronounced
the most direct expression of its hazard SAFE, because a permissive arm returned
first. **The scoping half is what stops the rule being misapplied:** the hazard
lives where arms are PATTERNS, not equality. `bk_pane_kill_authorized`'s
ALLOW-first ordering is sound because its two state lists are measured DISJOINT
under `==`, and would stop being sound the day either gained a glob.

**`#1119` — `is_routing_body` inverted to `is_mock_body`.** A hand-off DENYLIST
with a permissive default, deciding 86% of its corpus, is replaced by POSITIVE
PROOF: every simple command must be a keyword, a builtin, a body-local function,
or a named external that cannot execute another program (`awk`, `sed`, `find`,
`xargs`, `env` and the shells are deliberately EXCLUDED, and that exclusion list
is the load-bearing half). It found a LIVE escape in production code:
`monitor/cc-harness/demo.sh` resolved its shim target with `type -P tmux`, which
in this workspace is the PATH-front `monitor/tmuxwrap`, and under `--here` wrote
`exec <wrapper> "$@"` with **no `-L` pin**. Fixed via the shared
`nx_real_tmux_bin`. It does NOT reproduce the false positive that sank the naive
fix — `test-paste-followup.sh:94` is asserted as a control.

**`#1130` — the pipefail axis enrolled on a QUOTED DATA STRING.** Scoping decided
and stated: *an executed command string is its own pipefail scope*. Manifest
114 -> 115: **+1** the true positive at `test-service-health-selfmatch.sh:156`,
**-2** prose banners. Three readings were measured before one shipped — deleting
quoted spans loses 28 of 114 rows (a reader's KIND is decided by its quoted
ARGUMENTS), per-line masking loses one, carrying the mask alone loses eight — so
"quoted" is believed only when both readings agree.

Two shared primitives repaired underneath, both measured: `shf_strip_comments`
took its cross-line quote carry from the WHOLE line, so an apostrophe in comment
prose leaked every following comment as code (`#1177`); and `_shell_quotes.awk`
called `"$(cmd | head -1)"` TEXT, losing nine live early-exit-reader sites.

Assertion counts rose 17->24, 23->28, +11 new. Every guard proven able to FAIL by
a planted fixture AND a recorded mutation DIFF — six mutants, six reds.

### Added — a written rollback procedure, and an upgrade page that names the new loud refusals (`#1151`)

Prerequisites 3 and 5 of the `dev` -> `main` promotion evaluation.

**`docs/operating/rollback.md` is new.** There was no rollback procedure
anywhere in the repo — no tag, no release, no candidate branch — so a
promotion was a one-way door. The page defaults to **reverting the merge**
rather than force-pushing `main`, because `nexus-code` ships as a rolling
`main` that other operators clone directly: once anyone has pulled, a
rewrite of the remote does not rewrite their tree, it only guarantees their
next pull conflicts. It also documents the trap that bites afterwards — a
reverted merge is still in `main`'s ancestry, so the eventual re-merge of
`dev` brings back the fix and **none** of the reverted commits, silently and
without a conflict, unless you revert the revert.

**`docs/operating/upgrading.md` gained two sections.** The file's blob was
byte-identical at `main` and `dev` across all 1003 commits of the gap, and
warned about none of the refusals added in that span. It now covers
`assert-shims-wrapped.sh` (exit 79 = NOT CHECKED, deliberately not 0),
`spawn-worker.sh` (19 = unwritable `NEXUS_STATE_DIR`, 78 = missing guard
template), `guards-for-diff.sh` (0/2/3/4/5, four of which are not
clearances), `tmux-socket-fits.sh` (3 = path over the 107-byte `sun_path`
budget), `mutation-gate.sh` (3/5), `public-mirror/build.sh` (6/7, and that
it destroys the checkout it runs from), and the two `proc-*-authorized`
helpers. It also states the reassuring half explicitly: **no config
migration** — `config/nexus.example.yml` carries the same six top-level keys
at both refs, having grown only in defaulted sub-keys.

`config/load.sh --check-identity`'s exit 4 is listed under *what did not
change*: it is present at both refs and only looks new to someone meeting it
for the first time after a long jump.


### Fixed — the `ng dashboard` verbs accepted input they could not honour and reported success anyway (`#1118`, `#1058`, `#959`, `#958`)

One defect on four surfaces, and the unifying sentence is **presence is not
uniqueness**. `cmd_dashboard_put`'s precondition asserted the markers were
PRESENT and never that they were UNIQUE — verbatim what `#1058` says about
`validate` and section headings.

**`#1118` — a put that published nothing, at rc 0, with three surfaces agreeing.**
**The cap is the mechanism, always** — the first version of this entry said the
opposite. Reproduced end-to-end against a stateful fake forge: a body with two
END markers LANDS (198,268 -> 198,301 B); a body with two START markers is
doubled by `_splice_body` (198,246 -> **396,127 B**) and swallowed; and a
perfectly healthy single marker pair at 240,117 B merges to 263,350 B and is
swallowed with rc 0, empty stderr and the freshness stamp written. So a
duplicated END alone is harmless, a duplicated START is a cause of the SIZE, and
the false step was "198,236 bytes, 64 KB under the cap, therefore not the cap" —
the cap applies to the MERGED body, which was never measured. The refusal fires
at `> 262144` and the swallow begins at `> 262144` (`put` refuses over the cap
and warns from 90%, splitting the total into dashboard region vs the prose
outside it so the operator can see whether trimming the dashboard can help).

The general fix is a **read-back from an INDEPENDENT GET**. The first version of
this shipped a read-back against the PATCH *response*, which the skeptic pass
measured to be structurally incapable of catching a swallow: an over-cap PATCH
returns 200 whose `.body` is **the body you sent** while the store keeps the old
one (`response_echoed_sent = YES` in every case measured on scratch issue
`#1128`; the limit is 262,144 **bytes** — 262,144 lands, 262,145 swallows). Six
tests "proved" that read-back worked against a mock that had the forge backwards.
There are now three guards, each named by what it actually catches: the size
refusal (the cap), a response comparison (corruption on *our* side — `jq -Rs`
silently substitutes invalid UTF-8 at rc 0), and an independent GET (the store,
and therefore any swallow). Cache and freshness stamp are written only once
verified. `rc 4` means *could not verify*, deliberately distinct from *failed*.
The GET is `#1010`'s `cmp` run in the opposite direction — that one refuses a
no-op that would buy false freshness; this one refuses a claim of success.

Two further causes the read-back covers, found while building it: `jq -Rs |
gh api --input -` is a **pipeline**, so a dead producer fed the PATCH empty
stdin while the pipeline reported rc 0 — and a body-less PATCH returns 200 with
the issue unchanged, which is the reported signature at any size. The payload is
now built to a file and the producer's rc tested. `jq -Rs` also silently
substitutes invalid UTF-8 (rc 0), which the read-back catches and no size check
could.

**`#1058` — `validate` answered presence and called it OK.** Now fails on a
duplicated required section (naming line numbers), names near-miss headings
(`## 🛑 Infra — …` is that section by intent and invisible to `grep -Fx`),
reports same-named sections that differ after their separator as a NOTE — the
shape actually reported — and stops printing a bare `OK` over any finding. Every
verdict now carries body size and section counts.

**`#959` — `put` accepted a full issue body and nested the markers.** Refused at
the input, and `get` now refuses to hand back a region containing a marker: `get`
produces what `put` consumes, so the compounding is one round-trip away and
`get` is where the cycle starts. `_splice_body` emits at most once so a
pre-existing nesting degrades instead of compounding. Deriving the population by
the property rather than by marker name found **two more** unguarded splice sites
`#959` did not enumerate — `cmd_nexus_identity` and `cmd_interactive_sessions`,
both upserting into the same overview issue, both discarding the PATCH response
entirely. Both now share one guard and one verified-PATCH helper.

**`#958` — `validate` read stdin and blamed the dashboard.** With no
`--body-file` it now validates the **live** dashboard, which is what the verb
name implies; `--body-file -` explicitly asks for stdin. Empty-input diagnostics
name the input, never the subject. `--body-file -` was documented in three
places and did not work at all — it died `body file not found: -`.

**Also fixed, found while repairing the live board:** the required-section check
ran against the dashboard REGION, so a `## Identity` pointer whose generated
block legitimately sits *above* the START marker was reported missing on every
put, forever — a warning structurally incapable of being right, in the
reassuring direction. It now searches the whole issue body, and when given only
a region it says what it could not see instead of asserting absence.

`#1010`'s UNCHANGED guard was exercised live and is correct; it is untouched.

### Fixed — three checks that reported a status they never measured (`#1056`, `#1078`, `#1053`)

One defect in three places: a confident answer about something the check did not
examine. Bundled so none of them reads as a local slip.

**`#1056` — `_nexus_fs_evidence` read `tail`'s status, not `df`'s.**
`if dfline=$(df -Ph "$path" 2>/dev/null | tail -1)` tests the pipe terminator,
which essentially always succeeds, so on a failing `df` the SUCCESS arm ran with
an empty `dfline` and printed `fs_source=` / `fs_avail=` blank — indistinguishable
from a filer that answered, inside the probe whose whole job is to prove a write
failure is not a storage outage. Restructured to capture `df`'s own status, and
to treat a successful-but-empty `df` as `unknown` too. `set -o pipefail` was NOT
used: `_lib.sh`'s header requires it to be safe to source from a shell that has
already configured its options.

**The issue's scope number was wrong and the swallow was LATENT, not live.**
`#1056` reported `_lib.sh` "referenced by 130 files, 112 of which set file-scope
pipefail, leaving roughly 18 sourcing contexts where the swallow is live". That
counts files MENTIONING the string `_lib.sh`, not files sourcing it. Re-derived
at `7c073a3` by actual source edges: **21** true sourcers of
`monitor/watcher/_lib.sh`, and **0** of them lack `pipefail` — so every shipped
call path already reached the honest `unknown` arm. The mutation test proves it:
against the restored defect, `[B/pipefail]` PASSES while `[B/nopipefail]` fails.
The defect is therefore the DEPENDENCY, not the reachability — a site whose
correctness rests on the sourcer having enabled an option the file's own header
disclaims. New suite `test-fs-evidence-df-status.sh` pins the option-independence.

**`#1078` — `test-ng-usage-flag-coverage.sh` declared no population.** It now
implements the `--population` protocol via its own `_ng_surface_scripts`
enumerator (the FULL `ng` surface by both delegation forms, not the narrower
`_delegated_scripts` walk), plus a `guard-populations.manifest` row. Verified
against `#1065`'s 14-file diff: the suite is now SELECTED and its `because it
reads` line names `monitor/send.sh` — the exact file whose addition reddened it.

**`#1078`'s residual gap was in `CLAUDE.md`, and the tool was honest.** The
contract file enumerated 2, 3 and 4 as non-clearances and said nothing about
**0**. Added that sentence. Re-measured at `7c073a3`: the blind-spot section is
byte-identical (556 bytes) at exit 0 and exit 3, so 0 deserves the same
suspicion. Written without an enrolment ratio, because
`test-claude-md-guards-for-diff.sh` Claim 7 forbids an `N of M` literal in that
bullet — it would rot within a day.

**`#1053` — already fixed by `#1054`; verified by execution, and its stated
mechanism corrected.** The ask ("`--run` should REFUSE, or explicitly qualify, a
population guard's green while untracked files are in the diff") is implemented
at `7c073a3` and fires. Measured with a planted probe, content held constant and
trackedness the only variable: untracked it is named under `BLIND TO`, its green
prints as `UNVERIFIED`, and `--run` exits 4; staged it goes red. **No code change
was made**, because the correct one already exists.

Its mechanism sentence is wrong, though: "a guard can be selected BECAUSE OF an
untracked file and then run blind over a tree that does not contain it" describes
two mutually exclusive conditions. Selection is `changed ∩ population`, so a
guard selected because of a file necessarily has that file in its population and
is therefore NOT blind to it. Measured on one run: `early-exit-reader-manifest`
was selected because of a TRACKED file and blind to the untracked probe;
`stub-claude-manifest` was selected because of the untracked probe and not blind
to it — its population walks the working tree, not `git ls-files`. The
consequence `#1053` describes is real; the route to it is one step different, and
tracked-only enumeration is a per-guard property rather than a universal one.

Found while fixing `#1056` and filed rather than folded in: `#1106`, where
`early-exit-readers.sh`'s pipefail axis is decided by a bare grep over whole files,
so a COMMENT naming `set -o pipefail` enrols a file onto a checked manifest's axis.
Latent today (115 rows either way, every comment-only match already on the axis by
inheritance) and reproducible (115 → 116 from one planted comment line). The `#1056`
fix comment names the option by description only for this reason.

### Changed — test-knob-default-agrees now DERIVES its knob table: 2 hand rows to 99 (`#995`)

The guard hand-enumerated its knobs — two rows — with no assertion that the
enumeration was complete. It had already missed a knob for exactly that reason
once (`#966`'s own new knob re-instantiated the hazard the fix was for), and
`KNOBS`' comment "Adding a knob means adding a row" is the instruction that had
already been forgotten. Re-derived at `3458180`, `_config.sh` resolves **99**
knobs with a numeric literal default. The guard covered 2.

**"Paste more rows" was not the fix, and that is the whole difficulty `#995`
identified.** Adding one legitimate row for a knob with the identical hazard
turned the guard red on **non-vacuity, not drift**:
`MONITOR_OVER_LIMIT_MAX_ATTEMPTS` has no `_config.sh` validation fallback at all
(spelling B absent **by design**) and its docstring is whitespace-padded past
the `E` regex. Its four real spellings all say `4` and agree. The five-spelling
model was specific to the two knobs it was written for.

What makes it extend is treating absence as a first-class state — legal, but not
free. Two independent properties:

- **AGREEMENT** — every PRESENT spelling of a knob's default names one number.
  Absence is not disagreement.
- **PRESENCE** — *which* spellings each knob has is pinned in
  `knob-default-spellings.manifest`. So a rename or reflow that makes an
  extraction silently return `""` reddens NAMING the knob, instead of collapsing
  the comparison to a smaller set that agrees. That was the vacuity failure the
  old per-spelling assertions existed to prevent, and it is the thing "just
  don't require every spelling" would have thrown away.

A, B, C and E are now derived; **D alone keeps a hand table**, because it names
a function-scoped local that cannot be discovered — `_emit_filters.sh` holds two
functions whose local is `cooldown`, at 300 and at 900, so a file-scoped scan
reports a false disagreement. That is the one place enumeration is still right.

- **`E` tolerates the padding these docstrings actually use.** The old form
  required one space; the repo's docstrings are column-aligned, arrow-annotated
  and backticked. At `3458180` the single-space form finds an `E` for **7** of
  99 knobs, the tolerant form for **17**.
- **Completeness is asserted, not assumed.** A derived list has the hand list's
  failure one level down: a knob written in a spelling the row regex does not
  recognise drops out silently and looks exactly like a knob that is not there.
  So the shape is counted independently — every `$("$_cfg" <key> <numeric>)`
  occurrence — and the parser must claim all 99.
- **No live drift.** 0 of 99 knobs divergent at `3458180`, and the zero is from
  an instrument shown to fire: the control mutates a real copy of `_config.sh`
  and runs the *same extractor* over it, requiring the victim to be named. Two
  end-to-end mutants on the real tree are killed — a consumer-side `${VAR:-N}`
  drift (agreement reddens) and a deleted docstring (the mask ratchet reddens,
  diffing `A-CE` → `A-C-`).
- `MONITOR_OVER_LIMIT_MAX_ATTEMPTS` — the knob `#995` used to show the model did
  not extend — is now covered, mask `A-CE`, green.

The mask distribution is the argument against pasting rows: only **6** of 99
knobs carry all four derivable spellings, and **20** carry `A` alone. Most knobs
legitimately have nothing to compare.

Three of this repo's own documented traps were hit while writing it, and each is
now recorded at the line that suffered it: `IFS=$'\t' read` COLLAPSES empty
fields (tab is IFS whitespace in bash), which shifted every column after the
first absent spelling and produced "93 of 99 divergent" on a tree whose real
answer is 0; `"$ce$d"` glued two command substitutions into one row because the
trailing newline is stripped; and a sed program built in DOUBLE quotes had
`$_cfg` expanded by the shell before sed ever saw it, so the mutation control
mutated nothing and passed for the wrong reason.

### Fixed — a predicate keyed on a string cannot tell the THING from the DESCRIPTION of the thing (`#1073`, `#1059`, `#1057`)

Three issues, one causal chain, so they land together rather than in a sequence
where each half is inert without the others.

- **`monitor/proc-exists-authorized` — a sanctioned existence check
  (`#1073`).** A process-EXISTENCE predicate keyed on a command line matches
  SIBLING AGENTS' argv, because agent prompts quote verbatim the thing being
  watched and `claude`'s argv **is** its prompt (one live pid measured at 15,265
  argv bytes). `proc-kill-authorized` does not reach it: that gates KILLS, and
  nothing consulted an authorization filter before deciding whether to keep
  WAITING. Measured on this board 2026-08-27, with a real job running: a
  correctly bracketed `ps -eo pid=,args= | grep -c '[g]uards-for-diff'`
  returned **12**, three of them live sibling `claude` processes in other
  sessions. The new helper keys on session ownership and pid identity, reads
  `/proc` directly (so it has no observer to self-match), and **owns the loop**
  — the caller never writes the `until`/`while`, so the polarity cannot be
  inverted. `--until-gone --match` is REFUSED at rc 2 on purpose: "nothing I
  own matches" is not "the job is gone", and a `setsid`-detached job of your
  own is invisible to any session-scoped match. Five exit codes, three of which
  are not answers — `3` (REFUSED, could not determine) is what breaks the
  both-directions failure, since a shell `until` loops on non-zero and a
  `while` loops on zero, so any two-valued predicate is read backwards by one
  of them.

- **Every matching guard rule is now delivered, not just the first (`#1057`).**
  `deliver()` ended in `exit 0`, so arm order was a silent priority list that
  nothing declared and nothing tested. Measured over **104,113** real
  `Bash`/`Monitor` command strings from 856 Claude Code transcripts:
  **7.8% of all warned-about commands (784 of 10,016) tripped more than one arm
  and were told about one.** Per-arm, `pipe-status` lost **428** deliveries,
  `git-push` 21.9%, `tmux-kill-session` 50% — and `tmux-kill-pane` **100% (0 of
  4)**, always eaten by `tmux-kill-server` above it. That family is the only one
  whose consequence the conf calls unrecoverable, and it was deliberately split
  into four tags (`#951` F2) so one verb could not spend the family's warning;
  row order re-introduced exactly that *within* the family. The cap is now 3
  (covering 104,099 of 104,113 commands in full) and, crucially, **announced**:
  withheld tags are NAMED in the payload and are not marked seen. A cap
  inferred from absence would be the same defect one level up.

- **`procmatch-self` no longer punishes the remedy it prescribes (`#1059`) —
  and the fix is the MESSAGE, not the trigger.** The arm told readers to
  "bracket the pattern" and then fired on exactly that; two agents in two
  sessions hit it independently, one on its first command. Suppressing on
  brackets — the issue's suggested direction — was measured **wrong**:
  bracketing closes the observer's own hit (3 → 0) and does nothing about a
  sibling's prompt-carried hit, so suppressing would have closed `#1059` by
  opening `#1073` wider. The arm therefore fires on both spellings and says
  something DIFFERENT to each; the bracketed variant credits the half that is
  closed and names the half that is not. The matcher also widened: `\bgrep\b`
  does not hold between `f` and `g`, so `fgrep`/`egrep`/`rg` were silent while
  carrying the identical hazard. `awk`/`sed` are a declared residual, pinned as
  a NEGATIVE, because `ps … | awk '{print $1}'` is the kill-list idiom
  `CLAUDE.md` blesses.

- **A new `procmatch-wait-ps` arm** for a wait loop keyed on `ps … | grep`,
  which previously received `procmatch-self`'s message — advice that does not
  touch the hazard, for a construct whose failure is silent non-termination.
  It could only be added once `#1057` was fixed: a new arm competing for a
  single delivery slot would have been a regression.

`CLAUDE.md` gains the entry, in a delimited block executed against real
own-session and foreign-session plants by
`monitor/watcher/test-claude-md-procmatch-argv.sh`, so it is checked rather
than asserted.

### Fixed — undefined-helper-lint: inert heredoc text could exempt a whole suite, and nothing could tell UNKNOWN from clean (`#1030`)

Two defects in `#989`'s `UNKNOWN` arm. **This is not a revert of `#989`** — that
change shrank the blind spot from 40% of suites to 8.3% at zero call-site cost,
and the pre-fix state was an active false positive. This is the residue that
shipped with it.

**F1 — the exemption fired on text that never executes.** The SOURCE scan read
the raw file; the CALL scan read `th_strip_heredocs "$f"`. Three lines apart. So
inert heredoc text decided whether a whole suite was checked or exempted: a
fixture containing `source "$LIB"` sets `unresolved_here`, and every finding in
that file is downgraded from UNDEFINED to UNKNOWN. The asymmetry is older than
`#989`; what `#989` changed is the consequence — an unresolved source used to
merely omit names from `reachable`, and now decides the verdict.

Re-derived at `3458180` using the lint's own resolver (one `printf` inside it,
so the population is the lint's and not a re-implementation): **169 suites, 14
with an unresolved source, 3 of them only because of heredoc text** —
`test-ambient-shell-option-scope.sh` (25 directives → 3 under the stripper),
`test-helper-honesty.sh` (6 → 2), `test-version-restart.sh` (5 → 2). The other
11 are byte-identical before and after: their `. "$LIB"` lines sit inside
`bash -c '…'` blocks, which are not heredocs, and their exemptions are
legitimate. After the fix: **11 exempt, and none newly so.**

**The lint exempted ITSELF**, through a fixture added by the change under
review. `#989` added a `<<'FXC'` heredoc to `test-helper-honesty.sh` — the
lint's own test suite — whose body contains `source "$LIB"`. Reproduced at
`3458180` and closed, same plant, two files, one run apart:

| plant `_argloop_stuck "…"` in | before | after |
|---|---|---|
| `test-helper-honesty.sh` (the lint's own suite) | rc 0, "1 call site UNKNOWN" | **rc 1, named as an offence** |
| `test-ng-close.sh` (not exempt — the control) | rc 1, named | rc 1, named (unchanged) |

**No silent fallback.** The old line was
`body=$(th_strip_heredocs "$f" 2>/dev/null) || body=$(cat "$f")`, and that `||`
is a silent revert to the raw file. It defeats the F1 fix *without breaking its
invariant* — both scans still read the same text — while the content goes back
to raw. A strip failure is now "could not look" for that file: counted, named,
REFUSED (exit 2). Same for an empty body from a non-empty file, which the old
`[[ -n "$body" ]] || continue` dropped in silence. Both arms are prospective:
0 of 169 suites hit either at `3458180`.

**That `||` was load-bearing, and what it was hiding is the finding.** In the
lint's own FIXTURE corpus the helper is a two-line stub (`assert_eq`,
`th_skip`), so `th_strip_heredocs` was **undefined** there — `type -t` empty,
the call returning rc 127 and zero bytes. Every `#989` fixture assertion has
been scanning raw, unstripped files for its whole life, and nothing said so.
The lint's potency harness was running the defect the lint exists to prosecute.
The fixture now carries the real helper and the real `_shell_quotes.awk`.

**F2 — nothing could tell UNKNOWN from clean.** `UNKNOWN` keeps rc 0 by design
and the summary always contains "suites"; those two facts were exactly what the
lint's only consumer asserted, and both hold identically at `0 UNKNOWN` and at
`N`. The `%d UNKNOWN` field was printed and read by nobody. The lint was in no
gate: `run-tests.sh`'s glob is `test-*.sh` (no match), and it is named in
neither `run-tests.sh`, `.github/workflows/`, nor `guard-populations.manifest`.

- **`uhl-unknown-callsites.manifest`** — the residue is DATA. `--unknown-set`
  emits it; a normal run compares and exits **4** on disagreement. 4, not 1:
  this file already insists a REFUSAL must not be mistaken for a FINDING, and a
  residue that moved is a third thing again.
- **Keyed on the CALL-SITE list, not the unresolved-SOURCE set** — an offence
  planted in a file already carrying an unresolvable source adds no source
  directive, so a source-set ratchet would miss the very mutant that motivates
  one. And on `<file>\t<name>`, not `file:line`: line numbers churn, and a
  noisy ratchet gets regenerated reflexively.
- **`test-helper-honesty.sh` now declares its population**, so
  `ng guards-for-diff` can select it — forwarding to the lint's own
  `--population` rather than restating it.

Sixteen new assertions, every one with a control that varies the axis the
mechanism varies on: the ratchet is driven by mutating the MANIFEST with the
corpus held constant, and the strip refusal by removing the shared quote
machine — which is also, exactly, how the fixture corpus had been failing all
along.


### Added — the `idle-orphan-async` loop closes itself (`#1071`)

Six workers, four windows, three clones, two repos, under three hours, all on
2026-08-26: each ended a turn holding external waits whose jobs had already
ended, and **each was unblocked only because the orchestrator noticed a row and
pasted.** The fourth landed ten minutes AFTER the issue was filed, in a worker
whose prompt carried the injected rule.

Every control existed and every control fired. The worker floor states the
ownership rule and is auto-injected; `hooks/async-launch-detect.sh` re-injects
it at the launch; the watcher detects the stall precisely, naming the exact
wait ids. **All three are advisory**, so the loop closed only when a
human-equivalent read the row. Three of those six workers produced the
session's sharpest findings while breaking the rule — this was never a
discipline problem, and "tell the worker harder" is the remedy that had already
failed six times.

Two halves, because they fix different things and only one of them is
sufficient on its own for anything.

- **`monitor/watcher/_orphan_async.sh` — the watcher now owns a wake loop for
  this class**, the same treatment `over-limit` has had since `#87`, and
  deliberately built in that file's shape. It fixes the STALL. Three gates, all
  asserted in both arms and all mutation-tested:
  - **it never wakes a worker whose job is still running.** Every wait is
    resolved first and a single `running` verdict suppresses the wake
    entirely. `idle-orphan-async` means *this worker has no way to wake*; it
    has never meant *the job is over*, and a self-healer that reaps live work
    is strictly worse than the stall it replaces.
  - **it never delivers into a pane with input queued** (`queued=1`), and
    re-probes that the pane still reads the class before pasting. `#1065`'s
    contract exists for this; a self-healing loop that double-delivers is
    worse than the stall.
  - **it never clears a wait.** The brief resumes first and names
    `declare-no-wait.sh` last, as the exception, with its precondition
    attached. Clearing a wait on a job that IS running destroys the only
    record that work is outstanding.

- **`monitor/async-run.sh` — a launcher that RETAINS the exit status.** This is
  the half that fixes TRUSTWORTHINESS, and nothing else in the change does.
  `--status <token>` answers three ways where a bare `nohup` answers one:
  `running`, `terminal rc=N`, and **`died`** — gone, and killed before it could
  report. That third verdict is the one the four `nohup` instances could not
  produce, and the reason it matters is that **an absent process is not a
  completed job**: a producer killed mid-write leaves a TRUNCATED, plausible
  intermediate, not an empty one, so it passes every emptiness check and
  silently shortens every number downstream. One of the six producers was at
  28 GB RSS against a 92.6 GB archive on a shared node, so OOM was live and
  unfalsifiable from inside the worker. Slurm already had this property via
  `sacct`; `setsid` + a status file gives it to local background work. Liveness
  is checked by pid IDENTITY (`/proc/<pid>/stat` field 22), not `kill -0`, so a
  recycled pid cannot turn a `died` into a confident `running`.

  **Measured while building it, and it corrects the folklore:** a bare
  `nohup … &` child SURVIVES the Bash tool call (reparented to init, ppid 1).
  What dies is the parent shell that would have reaped it. So the defect is not
  that the job is killed — it is that nothing anywhere records how it ended.
  The new `async-status` footgun row says exactly that, because a message
  claiming the job is killed sends the worker to fix the wrong thing.

- **One wait per JOB, not per CALL** (`monitor/hooks/async-launch-detect.sh`).
  A 15-job submission grid is a single Bash call carrying fifteen
  `Submitted batch job` lines; the hook took the first and synthesised a
  `syn-` token for the rest. A `syn-` id has no job behind it, so nothing can
  look it up — per-call tokenisation was manufacturing the unresolvable wait at
  exactly the shape (a dose grid) that is COMMON for this work. Every id is now
  parsed, and dismissal is per id, so `declare-no-wait` on one grid job no
  longer clears the other fourteen.

- **`sbatch --parsable` prints a BARE id**, which the canonical
  `Submitted batch job <id>` regex does not match — so it minted an
  unresolvable `syn-` token. **This, not per-call tokenisation, is the
  mechanism that produced the observed `slurm:syn-…` tokens**; corroborated
  live, and the two fixes address different paths. The bare-id reading is
  gated on `--parsable` appearing in the command, deliberately: a general
  numeric rule would register stray stdout as a job id, and a WRONG id is
  strictly worse than a `syn-` because `sacct` may resolve it to another
  job's `COMPLETED` and tell the worker its data is good.

- **The emit no longer offers clearing as a co-equal option.** The removal is
  asymmetric rather than stylistic: resuming a still-running worker costs one
  turn, clearing its wait destroys the record — and the emit cannot tell the
  cases apart, because it reports the absence of a resume mechanism, never the
  end of a job.

**Corrected after review.** The wake brief opened with `NONE of them is still
running` **unconditionally** — including when every wait resolved
`unresolvable`, the ordinary case for the `syn-` waits this issue is about.
Neither `unresolvable` (nothing was retained; the state is UNKNOWN) nor `died`
(no status written) entails "not running", and the loop wakes when nothing
resolved `running`, which is a different claim. That was this change's own
thesis — an absent record is not a finished job — inverted in the one artefact a
worker reads, and it would have had a worker consume a live job's partial
output. The header is now conditional; `RESUME YOUR TASK NOW` is unchanged,
because resuming is correct in every case and only the status claim was wrong.

**What this does NOT close, stated because half a fix presented as a whole one
is the failure mode this issue is about.** The footgun row is a `warn`, and
`warn` is advisory exactly like the three controls that already failed — it is
not the terminal half and must not be read as one. `deliver` marks a tag seen
BEFORE exiting, so even a `block` would be a one-shot speed bump. The terminal
half is the wake loop, which needs nothing from the worker at all. And for a
wait whose launcher retained no status, the wake loop can only report
`unresolvable`; it cannot reconstruct what was destroyed at launch. Only using
the status-preserving launcher does that, and only prospectively.


### Fixed — sigpipe lint: the header promised coverage the regex did not deliver (`#1029`)

`monitor/watcher/test-sigpipe-assertion-lint.sh`'s COVERAGE BOUNDARY said it
covers "**ANY** producer piped into `grep` with a `q` flag". The regex matched a
BARE `grep` sitting immediately after the pipe and carrying a SHORT `q` flag.
**Six spellings squarely inside that promise evaded it**, and all six carry the
real hazard — measured, not asserted: match on line 1 of a 200 001-byte payload
under `set -uo pipefail` with the status consumed, `rc=141` for every one, i.e.
pipeline FAILURE on a string that DOES match.

The gap that matters is not the regex's. `head` and `grep -m1` also evade, and
they are fine, because the header **declares** them out of scope. A declared gap
is a boundary; an undeclared one is a false promise — and the header is what the
next author reads before deciding whether their construct is covered. That is
why the header amendment was the mandatory half and the regex the optional one.
Both landed.

- **The boundary is now ENUMERATED, and every member is planted as a control.**
  Eleven reader spellings (short-flag clusters in either order, `--quiet`,
  `--silent`, `command`/`env` and the other command-word prefixes,
  path-qualified `/bin/grep`, `VAR=val` assignment prefixes, and combinations)
  and four pipe spellings (same-line, `\`-continuation, `|&`, and the
  trailing-pipe split). Twelve new controls, each asserted to be caught at a
  named file and line. The enumeration is executed, not asserted in prose.
- **The trailing-pipe split needed more than a regex**, which is why it outlived
  the other five: the pipe ends line N and the reader opens line N+1, and no
  single-line matcher can express that. The scan now keeps the previous line and
  pairs a single trailing pipe (never `||`) with a following covered reader. It
  is the exact mirror of the `\`-continuation direction `#630` closed.
- **`| sort -u` and one shared reader fragment.** `_GREPQ_READER` is defined once
  and used by both passes and by both scans (code and docs), so the same-line and
  split spellings cannot drift into two transcriptions of one idea — the `#616`
  lesson, where a control exercising a COPY of the matcher let
  `echo "$var" | grep -q` survive.
- **What is still NOT covered is now named**: a reader the source text does not
  spell as `grep` (`"$GREP" -q`, `eval`, an alias, `xargs grep -q`, and the
  `egrep`/`fgrep`/`zgrep`/`rg`/`ug` variants). The variant row is a measured
  boundary — `git grep -nE '\|[[:space:]]*(e|f|z)grep[[:space:]]+-[A-Za-z]*q'
  -- monitor` returns zero at `3458180` — not a hidden hole.

**Widening the matcher immediately surfaced TWO LIVE SITES**, neither a plant,
both sitting inside the boundary sentence and outside the predicate the whole
time:

| site | spelling |
|---|---|
| `monitor/remote-forced-command.sh:410` | `\| LC_ALL=C grep -q` |
| `monitor/watcher/test-tmux-window-resolver.sh:784` | `\| LC_ALL=C command grep -q` |

**Both are defence in depth, not live fail-opens.** An earlier draft of this
entry called the first "fails OPEN on a security check". That was overstated,
and the correction is recorded rather than quietly dropped, because an
overstated severity that becomes a lineage's canonical example is worse than no
example — it is the sentence everyone cites.

`remote-forced-command.sh:410` is the non-printable-byte refusal on the remote
channel's forced command, and `set -uo pipefail` **is** in scope (line 111) with
the pipeline's status **as** the `if` condition — so an inverted verdict would
take the ELSE branch and admit the byte. It cannot fire *there*: three lines
above, `case "$CMD" in *$'\n'*) refuse 12 …` rejects any embedded newline and
`refuse` exits, so `$CMD` is **single-line by construction**, and grep must read
a complete line before it can match. `test-tmux-window-resolver.sh:784` decodes
one source line, so its payload is a few hundred bytes — far below the buffer
the hazard needs.

Measured on the exact source shape, `set -uo pipefail`, non-printable byte at
position 1, **ten trials per size** (it is a race, so one sample is not a
measurement):

| payload | result |
|---|---|
| single-line, 1 KB · 70 KB · 200 KB · 2 MB | REFUSED 10/10 at every size |
| multi-line, 8 KB · 32 KB · 60 KB | REFUSED 10/10 |
| multi-line, 65 KB | ADMITTED 2/10 |
| multi-line, 70 KB | ADMITTED 6/10 |
| multi-line, 100 KB · 200 KB | ADMITTED 10/10 (`rc=141`) |

So the hazard is real, requires **multi-line** input, and its onset is the
64 KiB pipe buffer — a probabilistic transition band, not a threshold. That
refines `#1029`'s own framing: `printf` does keep writing past the match, but
whether that write *blocks* long enough to see EPIPE is governed by the buffer.
The durable discriminator remains match **position** — a match on the last line
can never fire, at any size.

The conversion is still right, and that is why these sites are converted rather
than annotated: what protects line 410 is a newline refusal three lines away,
belonging to a different concern. Move it, weaken it, or copy the idiom to a
site with no such guard, and the hazard is live with nothing saying so. Both
were shown byte-equivalent to the herestring form first, across control bytes,
UTF-8, tab, embedded newline and empty input (`grep` strips line terminators, so
the added newline changes no verdict). Reverting either conversion, one at a
time, reddens case 2 by name: rc 1, exactly one `FAIL: sigpipe idiom`.

**And the trailing-pipe pass fired on the remedy it prescribes.** `|` is
markdown's column separator, so every table row ends in one, and a table above a
shell snippet made the pass flag the lint's own prescribed replacement —
measured: `monitor/flags.md:6:grep -q needle <<<"$var"`. That is `#1059`
recurring in a different lint hours after its fix merged as `#1090`. The pass
now excludes markdown table rows and refuses to carry a pipe from a prose
comment into a code line, with a **negative and a positive control on each
axis** — because "stop flagging the table" is also satisfied by switching the
pass off, and only the pair rules that out.

One trap recorded because it bit inside this change and is invisible: awk
DYNAMIC regexes degrade `\|` to a plain `|` with a warning, which turned
`(^|[^|])\|&?[[:space:]]*$` into an alternation matching the EMPTY STRING at
the end of every line — a precondition true everywhere, so the conjunction
reported its second half alone. **274 false hits** on this tree with the
backslash spelling, **0** with `[|]`. Same family as everything else in this
file: a predicate quietly wider than the property it stands for.


### Fixed — verification surfaces that lied about themselves (`#895`, `#884`, `#885`, `#940`)

Four surfaces that report on OTHER work. Each failed in the direction of
"everything is fine", and `#895` failed in the direction of authorising a kill.

- **A report could authorize its own retirement** (`#895`). `#` is in
  `_skeptic_stated_disposition`'s `structural_only` strip set, so a markdown
  HEADING was classified as EMPHASIS and `## Disposition: no-further-pass`
  parsed as a governing field statement. Measured end-to-end: `ng
  skeptic-disposition` returned `state=no-further-pass … detail=stated`, which
  is `retire-preflight.sh`'s "gate does not apply" arm — a section title
  clearing the window's own `tmux kill-window`. It also SILENCED a contradicting
  request: the field scan short-circuits before prose, so the same body without
  the heading returns `second-pass prose inferred`, and adding a title overrode
  an author asking for another pass.

  The repo had already made this ruling and applied it in ONE place: `#855`
  carved headings out at `report-check`, but that carve-out is reachable only
  from `unreadable` — so a heading with an ILLEGAL value was a title while the
  same heading with a LEGAL one was promoted to a statement. **The value decided
  whether the line was a title.**

  **A `#`-prefixed line is now refused in BOTH parse modes, and the frontmatter
  half is the worse one.** The first version of this fix scoped the rule to
  `want == "body"`, reasoning that frontmatter is YAML and `###` is not a heading
  there. The premise is right and the conclusion was backwards: in YAML a leading
  `#` is a **comment**, so the line is *more* disabled than a heading, not less —
  and reading it as a statement meant **commenting a disposition out activated
  it**. The syntax whose entire meaning is "ignore this line" authorised an
  irreversible `tmux kill-window`, and commenting a field out is the most natural
  way there is to neutralise one. Measured at the first head: `# disposition:
  no-further-pass`, its indented form, `#disposition: …` and `### Disposition: …`
  all returned `no-further-pass frontmatter stated`, unchanged from `e256d4a`.
  Caught by the `#955` skeptic; it is `#895` itself, one `want` value over.

  **Round 3 removed the space requirement from the body arm too** (`#962`). The
  mode-specific version above still read `#disposition: no-further-pass` in the
  BODY as a governing field — measured end-to-end at `defbb8e8`:
  `no-further-pass body stated`, then `retire-preflight` rc 0 `safe=1`. That is
  the same asymmetry, surviving in the other direction: the demonstrated
  spelling fixed, the more natural one left open, on the irreversible path.
  Markdown has no comment syntax, so the shape is genuinely ambiguous; the tie
  is broken by FAIL DIRECTION, which is the only argument this parser supports.
  Both arms are now one regex and the MODE still picks the detail string. **A
  non-ATX body line reports the shared body detail** — a declared imprecision,
  not an oversight: a second mark was refused because the `<n>h` suffix is
  `report-check`'s `#855` carve-out flag, so splitting it would change write
  time to improve a hint string. Pinned by its own assertion.

  Re-measured on the LIVE corpus rather than a frozen snapshot, with a positive
  control in the same run: **0 of 1,166 reports change verdict**
  (`2026-08-15T12:21Z`). Note the predicate — `^[[:space:]]*#[^[:space:]#].*disposition:`
  returns 0 against the literal string `#disposition: x`, because it requires a
  character *between* the `#` and the word. It cannot match the spelling it
  costs.

  The modes need different marks in what they are CALLED, and one regex would
  have missed the frontmatter gap when the arms still differed: an ATX heading
  requires the space (`#{1,6}` then blank), a YAML comment does not and may be
  indented — so `#disposition: x` is a comment in YAML and not a heading in
  markdown. Frontmatter resolves
  `unreadable frontmatter hash-prefixed-line-is-a-yaml-comment`, body resolves
  `unreadable body heading-is-a-section-title`; the detail names the mark the
  author actually wrote, because the remedies differ. A commented line beside a
  real field does not shadow it.

  A heading now resolves `unreadable body heading-is-a-section-title`.
  Deliberately `unreadable` and not a skip: `## Disposition: second-pass`
  currently BLOCKS retirement, and silently dropping it would move that report
  from NO-GO to proceed — ignoring text must never relax a gate. Write time is
  unchanged by construction: `unreadable source=body` is exactly the state
  `#855`'s carve-out consumes, so an ordinary worker writing `### Disposition:
  fix at source` still passes `report-check`. **Zero of 1,133 corpus reports
  change verdict** (frozen snapshot; the three carrying a heading-shaped line
  are fenced or already governed by frontmatter), asserted differentially.

- **A comment claiming an invariant nothing asserted** (`#955` skeptic round 3).
  `ci-head-attempts.sh` stated the `unexecuted`-only wording was preserved
  "BYTE-FOR-BYTE … asserted differentially in test-ci-head-attempts.sh". Both
  halves were false. Measured across all 42 fixtures at `423f92e` vs `50d1621`,
  **6 outputs changed** — five the intended `#884`/`#885` cases, and one the rc-9
  stale-merge-ref arm (`unexecuted`-only) where folding the count into
  `_excl_count_phrase` moved a LINE BREAK. Cosmetic, and unavoidable while the
  phrase is dynamic. Nothing in the suite compares bytes
  (`grep -c 'diff <('` → 0). The comment now says what is preserved (the
  WORDING) and what is not (the wrapping), and the wording is pinned by a real
  assertion on that arm, including the ABSENCE of the non-verdict clause. An
  over-claiming comment in the PR that exists to remove over-claiming
  verification surfaces was the whole point of correcting it rather than
  deleting it.

- **Universal claims qualified for one member of the excluded set and not the
  other** (`#884`). A run that COMPLETED with a conclusion that is neither
  `success` nor `failure` was marked `--  … — not a verdict` in the rows,
  counted into `concluded_n`, and counted by nothing else — so at rc 0
  `ci-head-attempts.sh` printed `every completed run at this head is a
  FIRST-PASS success` three lines under its own row saying otherwise. Five claim
  sites each branched on `(( unexecuted ))` privately, so the second member was
  never taught to four of them. Membership and its wording now live in one place
  (`_excl_any` / `_excl_clause` / `_excl_count_phrase`) and the sites ask; a
  third member is qualified into all five by construction. Output with nothing
  excluded is byte-identical.

- **A shared disclosure audited by whether it is CALLED** (`#885`). Presence was
  never the property. Verified on the audit arm: with a GATING band that
  concluded `failure` having executed ZERO steps, the audit reports
  `UNEXECUTED-RUN … ABSENCE of verdict (exit 4)`, the verdict says `the
  expected-band audit above did NOT come back clean (rc 4)`, and the shared note
  said `That does NOT drive the verdict above` — all in one output. The
  unexecuted run was the sole cause of the verdict it disclaimed. Causality is a
  property of the ARM, so it is now the caller's to state
  (`independent|drives|unknown`); the audit arm says `unknown`, because its rc 4
  may come from an unexecuted run OR a missing band and this helper cannot tell
  which. An absent argument resolves to `unknown` — the previous default was a
  CLAIM.

- **`#656`'s `comment_st=edited` arm was asserted nowhere** (`#940`).
  `grep -n 'EDITED|comment_st=edited|composed body changed'` over
  `test-ng-wrap-up.sh` returned empty, so the `#656`/`#873` "they compose to
  cover the whole case" claim rested on an untested mechanism. Now driven
  behaviourally — the comment must CARRY the correction, via PATCH on the
  existing comment, with no duplicate POST — plus a discriminator (an
  asset-link-only re-wrap must log `updated`, not `edited`) and the failure
  direction (`MOCK_PATCH_FAIL_ON=2` fails the body edit while the re-point
  succeeds; the verb must exit non-zero and not claim publication). No assertion
  greps `ng` for the string: that would be a presence test, i.e. `#885` one
  level up.

### Added — the disposition gate records what it read (`#962`)

`retire-preflight.sh`'s check 1c decided whether an irreversible
`tmux kill-window` may proceed and **wrote nothing**. Every other check on that
path leaves a trace — 1b clears a marker, the releases write a
`.cleared-rationale`, the kill itself logs `window-close` — so this was the one
decision on the kill path that could not be reconstructed afterwards.

Measured cost, and it is why this is worth its own change: asked how many
retirements were authorised on a disposition belonging to a **different task**,
one of two candidate windows was **UNDETERMINABLE** — not because nothing
happened, but because no record of the decision exists. The other was answerable
only because a `window-close` happened to be logged ten hours later. The action
log holds 210 `window-close` events spanning 2026-05-08 → 2026-08-15 and **zero**
on 2026-08-08/09, which is exactly the window the unanswerable case falls in.

`skeptic-disposition-gate` now records the window, the state, the probe rc, the
report that governed and that report's mtime, on **every** evaluation.

- **It records; it never decides.** Kill semantics are untouched — asserted on
  both verdicts, since a record written only when the gate proceeds would be the
  same blind spot in a smaller costume.
- **Emitted BEFORE the probe-failure arm**, so the `unknown` / could-not-run case
  is recorded too. "The gate could not look" is the answer a later audit most
  needs, and an after-the-arm placement drops precisely it. Pinned by its own
  assertion, and by a mutant that moves the emit after the arm and fails that
  assertion alone.
- **Fail-open, deliberately**, against this file's usual direction: a logging
  failure is not evidence about the window, and letting it block would turn a
  full disk into a board-wide stall. Bounded (`timeout`) and detached from the
  script's exit status. Asserted with a genuinely broken log path, not argued.

Groundwork for `#962` proper: it converts that class from *unknowable* to
*countable* without touching the parser or the gate's decision, so it can land
ahead of any semantic change.


### Fixed

- **A `watcher_alert=` block re-emitted on every `comment_surface` fire, so a
  GitHub outage stormed the operator channel the alert exists to protect.**
  Measured on the 2026-08-17 GraphQL 503: ONE escalation produced **62 pastes
  in ten minutes**, every one byte-identical and carrying the same frozen
  `held_s=2403` (<your-org>/nexus-code#966). The recovery then did it again,
  harder — **51 pastes** of a block generated exactly once. Across the whole
  100-minute outage the operator channel carried **113 pastes conveying two
  generator edges**; post-change the same outage delivers **5**
  (1 escalation + 3 restatements with live `held_s` + 1 recovery, under the
  measured ~602 s poll cadence — 4 if the last restatement is edged out by
  drift, which it nearly is).

  **The frozen value is the diagnosis, and it points away from the obvious
  suspect.** `_graphql_note_failure` is already edge-triggered and worked
  perfectly throughout — `announced=` never moved off its 10:45:41 value, which
  is precisely why `held_s` never advanced. So the filed remedy ("honour
  `announced` on the emit path") described a contract that was already
  honoured, and a generator-side fix had nothing to fix. The same is true of
  the siblings: `graphql-backoff` keys a sentinel on (surface, armed),
  `rate-limit` on (surface, reset), and `ingest-recovered` deletes its state
  file as it emits. All four generators are edge-triggered; all four storm.

  **The defect is delivery.** `_compose_gh_now` `cat`s
  `<stage>/github_poll.out` without consuming it, and `github_poll` refreshes
  that file only every 600 s, so every `comment_surface` fire (15 s base, 5 s
  under the nudge override) re-reads the same bytes. That replay is *correct*
  for comments, which the pipeline damps — but every hop of
  `_gh_filter_dedup_pipeline` dispatches on the recognised emit-header shapes
  `^(issue|pr|pr_review|issue_new|mention|cross_repo)=` and takes its DEFAULT
  ARM on anything else, so an alert was forwarded by all eight. (The predicate
  is the default arm, **not** id-keying: only the five damping hops key on
  `id=<N>`; `_filter_to_user_author` keys on `author=`, `_filter_skip_marker`
  on body content, `_filter_cross_repo_surface` on the mention shapes, and all
  three would have forwarded an alert that DID carry an id.) So it passed, and
  `_v2_task_comment_surface` pastes unconditionally (its dedup gate is
  deliberately bypassed for comment-bearing bodies). Nothing in the chain could
  express an alert. The storm ended only when the 600 s tick happened to
  replace the staged bytes with an empty file — an external event, not a
  damper. `compose_emit` saw the same content and *did* suppress it
  (`emit-dedup: suppressed identical-hash emit`); only the comment path had no
  gate.

  `_filter_alert_cooldown` (hop 8) supplies the identity the pipeline was
  missing, keyed on the alert's actual state-machine subject — its **surface** —
  rather than on a comment id it will never have. A **kind** change passes
  immediately, so a recovery is never swallowed by the hold its own degraded
  alert took out (an `ingest-recovered` lost that way is strictly worse than
  the storm: the operator cannot then distinguish "recovered" from "watcher
  died"). Changed **content** passes immediately, so a re-nag at a new
  `held_s` is never delayed. Otherwise the block is held for
  `MONITOR_ALERT_EMIT_COOLDOWN_SECONDS` — default **900**, a bound set by the
  600 s staging window rather than by taste: below it, one staged generation
  still lands twice.

  **Coverage boundary, stated exactly.** This closes the replay of a staged
  alert through `_gh_filter_dedup_pipeline`, which is the path all four current
  alert kinds take, and it is keyed on the `watcher_alert=` shape rather than
  on any one kind — so a future alert joins the damper by construction. It does
  NOT give the operator a lever to mute a specific alert by hand:
  `ng suppress-emit` still accepts only `comment:<id>`, and the `signature:`
  prefix `_filter_suppression`'s header reserves is still unimplemented
  (`#966` item 2's residual). It also does not touch the GraphQL-only ingest
  path, so an outage still degrades comment freshness — it is merely quiet
  about it now.

  The fixture was written FIRST and witnessed the storm (6 fires → 6 emits;
  siblings 4 → 4) before the fix existed, and it carries a negative control
  that reproduces `#966` on demand by setting the knob to `0`. Removing the
  pipeline hop re-fails it, so the wiring is load-bearing and not merely the
  function. Extended `test-comment-surface.sh`, whose case (4) already owned
  the cooldown-exclusivity contract alert blocks were escaping.

- **…and the silent half of the same outage: a still-degraded surface restated
  only once an hour.** `monitor.graphql.degraded_remind_seconds` (
  `MONITOR_GRAPHQL_DEGRADED_REMIND_SECONDS`) default **3600 → 900**.

  The storm and this are two halves of one incident, and fixing only the first
  makes the second worse. Measured 2026-08-17: the escalation announced at
  10:45:41, the emit stream stormed until ~10:56, then went quiet for the rest
  of the hour while `issue_comments` kept failing — `count` 5 → 8 by 11:15:40,
  zero recoveries. **Silence is not neutral here**: a real recovery *does* emit
  `ingest-recovered`, so an operator reading quiet as resolution is reading the
  design correctly and being misled. Across one outage the channel was
  unreadable while storming and misleading once quiet.

  **This is a period change, not a new mechanism** — and that distinction is
  the finding. `announced=` + the remind window is a working re-nag; the
  25-minute observation that prompted this sat *inside* the 3600 s default
  rather than outside a broken feature, so "it goes silent" was measuring the
  interval, not an absence. Worth stating because the remedy that follows from
  "no restatement exists" (make escalation purely edge-triggered, mirroring
  `_graphql_note_success`) would have **deleted** the restatement and made the
  silent half permanent.

  900 is bounded on both sides. Below 600 buys nothing: `_graphql_note_failure`
  is only called from the `github_poll` path, so the effective period is the
  window rounded UP to a multiple of the 600 s poll — 900 restates every second
  poll (~20 min), not every 15. Above ~1800 a restatement stops reading as a
  heartbeat and starts reading as a new incident.

  Each restatement recomputes `held_s` from `first`, so it carries a **live**
  age rather than the frozen `held_s=2403` the storm repeated — a heartbeat
  that repeats a stale number is just a slower storm, so the fixture asserts
  the values are distinct AND strictly increasing, behind an explicit vacuity
  guard (with one emitted block those two assertions are 1-of-1 unique and
  trivially sorted — they would pass while witnessing nothing, and that is the
  default state of the code they guard).

  The two halves compose, and the conjunction is what an operator experiences:
  `test-comment-surface.sh` (5c) drives a whole simulated outage through the
  real generator and the real pipeline on one shimmed clock, and asserts the
  stream carries **exactly one delivery per generator EDGE** — escalate,
  restate, recover — across eleven pipeline re-reads. Reverting the default to
  3600 re-fails it, so the change is load-bearing in both suites.

### Added

- **`test-knob-default-agrees.sh` — a knob's default is spelled in five places,
  and only one of them is the one production reads.** `_config.sh` sets AND
  EXPORTS every `MONITOR_*` knob at startup, so the `${MONITOR_…:-N}` fallback
  in the consuming function is unreachable under the running watcher — while
  being exactly the branch a unit test takes, because suites source the consumer
  directly and never load `_config.sh`. The two can diverge with the suite
  staying green, in the direction that matters: the tests move and production
  does not.

  Both instances came from <your-org>/nexus-code#966 itself. The first
  (`MONITOR_GRAPHQL_DEGRADED_REMIND_SECONDS`) was caught by hand and prompted a
  knob-SPECIFIC guard. The fix's own new knob
  (`MONITOR_ALERT_EMIT_COOLDOWN_SECONDS`) then re-instantiated the hazard, and
  that guard could not see it — **a fix re-instantiating the defect class it
  closes, and a guard too narrow to notice**. Demonstrated as a surviving
  mutant: mutating the PRODUCTION default 900 → 1800 produced **0 failures**
  across three suites, while mutating the DEAD copy 900 → 0 produced **9**.

  So the guard is table-driven over knobs — the only version that could have
  caught the second instance — holding five spellings together per knob
  (config-lookup default, config validation fallback, the consumer's
  `${…:-N}`, the consumer's own validation fallback, and the docstring naming a
  number). Adding a knob is one row. It asserts AGREEMENT, never a value:
  pinning the number would add a sixth place to forget.

  Two vacuity traps surfaced inside the guard while writing it, both caught by
  its own non-vacuity assertions rather than by inspection — the `_config.sh`
  validation fallback is written `[[ … ]] || VAR=N` so a line-start anchor
  extracted nothing, and the agreement check used `sort -u | grep -c .`, which
  DROPS an empty value and so passed on four spellings while never reading the
  fifth. A guard that cannot distinguish agreement from absence reads as
  coverage while providing none.

  Not a substitute for the class remedy: only knobs somebody enrols are
  covered. A lint over every `${MONITOR_*:-…}` whose variable is also assigned
  in `_config.sh` needs no enrolment step and remains the right end state.

### Fixed

- **The footgun guard was registered on `Bash` alone, and a matched-but-seen
  rule ended the whole hook.** Two independent reachability defects in
  `bash-footgun-guard.sh`, found while auditing a 5h20m self-matching wait-loop
  wedge (`#927`).
  (1) `Monitor` carries `.tool_input.command` into the same shell as `Bash`,
  so every rule in the conf was reachable through an unguarded path —
  measured: the byte-identical command warned via `Bash` and was silent via
  `Monitor`. Worse, the conf's own `foreground-sleep` row *sends workers to
  `Monitor` by name* to wait on async work, which is precisely where the
  wedging shape is written; 67 windows had received that advice. The guard is
  now registered `Bash|Monitor` and gates on a tool allowlist. `PreToolUse`
  does fire for `Monitor` (`tool_name=Monitor`) — verified against the real
  binary, not assumed.
  (2) `already_seen "$tag" && exit 0` left the entire hook rather than the row,
  so the first already-seen match disarmed every later rule for that command —
  including the three in-code checks, which sit after the conf loop and were
  the most exposed. 207 of 421 live windows carried two or more sentinels, i.e.
  were already in that muted regime. A seen tag now skips its row and the scan
  continues. The noise budget is unchanged: still at most ONE reminder per
  command, since a wall of reminders is how a guard gets switched off — the fix
  changes which one you get from *none* to *the first you have not seen*.
  `block` severity now outranks row order so a severe rule added late in the
  conf cannot be pre-empted by an advisory above it.
  Not fixed here, same shape, filed separately: `gh-write-guard.sh:38` and
  `async-launch-detect.sh:86` are also `Bash`-only, and `Monitor`'s own
  documentation demonstrates `gh api` poll loops. The latter is `#936` rather
  than folded in, because it feeds `external_waits` → `idle-orphan-async`,
  which is on the kill allowlist (`_BK_KILL_OK_STATES`) — widening it changes
  retirement AUTHORIZATION, not just detection.

  **On the incident that prompted this, since the naive reading is wrong in
  both directions.** The miss had TWO causes, and separating them needs the
  DEPLOYED tree rather than the commit graph:
  - `procmatch-wait` did not exist in the deployed tree. The wedge launched
    06:58:09 with `3a5d2d9` checked out (`procmatch-wait=0`); the rule first
    deployed at 08:12:37 (`79fabfd`) — a margin of **1h14m**. `3bbcfc0` was
    *authored* 2026-08-09 and merged with *committer* date 2026-08-14 07:36;
    neither dates when it could first fire. **Deployment is the axis**, and
    it has to be measured by walking EVERY reflog entry across the window —
    a sampled subset can only ever report the transition at its own last
    sampled ref, which is a probe whose shape guarantees its answer.
  - `pkill-self` DID exist and FAILED TO MATCH. The deployed row was
    `\bpgrep[[:space:]]+-[a-zA-Z]*f`, requiring `-…f` immediately after the
    command, so `pgrep -u "$USER" -f …` was silent. `3bbcfc0` closed that gap
    too, as its subject says; all four flag orders now warn.

  So the accurate statement is "no deployed rule **matched**", not "no rule
  addressed this" — the guard came closer than the absence alone suggests.

- **A registry healthcheck could report `healthy` forever with nothing running**
  (`#891`). `bash -c "$health"` puts the entire health string — pattern included
  — into a process's argv, so a `pgrep -f` healthcheck matches ITSELF. The
  failure direction is what makes it worse than its siblings: it is a **boolean
  that is always true**, so the supervisor never restarts the dead service and
  nothing logs a fault. `#869` (kill-side ownership) and `#871` (the wait-side
  hook guard) both miss it, being neither a kill nor a wait.
  **The safe set is narrower than the issue stated.** bash only sheds the string
  by EXEC'ing, and it only execs a BARE simple command — measured on bash
  4.4.20, nothing running, rc=1 correct: `pgrep -f M` → 1, but
  `pgrep -f M >/dev/null` → **0**, `… 2>/dev/null` → **0**, `… && true` → 0,
  `( … )` → 0, `exec pgrep -f M` → 1. A redirection is idiomatic in a
  healthcheck, so "keep it simple" was never a usable rule. Both sites now feed
  the script over a pipe (`bash <(printf '%s' "$health")`), so the argv carries
  no pattern under any shape; process substitution writes nothing to disk, which
  a temp-file variant would — and that would fail closed under the read-only-FS
  degraded mode (`#473`), restarting working services exactly when the tree can
  least cope.
  **TWO sites, not one.** `#891` names `bootstrap-recover.sh:358`;
  `monitor/watcher/_service_health.sh:287` carries a deliberate inline replica
  and is the consequential one — it runs every ~120s and drives auto-restart.
  Both fixed and both exercised. Live registry audited: 9 of 9 services use bare
  simple health strings, so this was **latent, not silencing** anything today.
  Declared out of scope, with controls proving each is a different mechanism:
  status masking (`cmd ; true`, `cmd | head` return the last stage's status —
  `false | head -1` is rc 0 with no process predicate at all) and
  `ps … | grep P` (the self-match is grep's argv inside ps's OUTPUT, guarded at
  authorship by `procmatch-self`).

### Added

- **tmux server lethality is now guarded in the SESSION, not only linted in the
  corpus** (`#889`). `bash-footgun-guard` had no tmux pattern at all: the board
  could be ended by a command no guard inspected.
  `monitor/cc-harness/lint-no-tmux-server-kill.sh` scans FILES; nothing read the
  live command a worker was about to run. Four rows, classification aligned with
  that lint's scanner so the two can be diffed: `kill-server` with no `-L`/`-S`
  on the same command, and `kill-session`/`kill-window`/`kill-pane` with no
  `-t`.
  **Placed FIRST in the conf and asserted there**, behaviourally and textually.
  Rows are first-match-wins, so position IS priority, and this is the only
  footgun in the file whose consequence is unrecoverable from inside the sandbox
  (`bwrap` is PID 1 running tmux under `--die-with-parent`). On 2026-08-09 the
  server died and took the watcher, all 17 worker windows, the services window
  and the operator's own session.
  **THE 08-09 CAUSE REMAINS UNATTRIBUTED** — the watcher died mid-write, its log
  ends cleanly at 19:58:11 with no cause recorded, and no worker transcript
  contains a kill verb. These rows guard a CLASS; the messages say so, and an
  assertion pins that they do not imply a known mechanism.
  The premise behind the untargeted rows was verified once out of band on a
  private `-S` socket asserted unequal to the board's: an untargeted
  `kill-window` on the last window of the last session leaves "no server
  running", while a targeted kill with a second window present does not. The
  shipped suite hands STRINGS to the guard and never invokes tmux.
  Seven legitimate forms are pinned as controls (`list-windows`, an alias to a
  non-kill, `kill-window -t a:2`, `kill-window -a -t a:1`, a targeted kill
  chained with `new-window`, `display-message -p`, `kill-session -t <absent>`)
  plus the prescribed pinned-private-server idiom, because a guard that flags
  correct window management on a 19-window board is suppressed by the first
  person under time pressure — which removes the only protection against an
  unrecoverable event.

- **`ng wrap-up` could publish NOTHING and still exit `0`, when the report had
  genuinely changed** (<your-org>/nexus-code#862). Two conventions, each correct,
  jointly silent: reports are **append-only**, and the link comment is composed
  from `## Summary` alone. So a superseding verdict written where the convention
  says to write it — appended further down — leaves the composed body
  byte-identical. `wrap-up` re-pointed the asset link, printed
  `unchanged … nothing to publish` (literally true), and returned `0`. The
  report moved, the thread did not, and nobody was told; the only artefact was
  an absence.

  `#656` had already closed the adjacent case where `## Summary` *itself*
  changed — that now edits the comment in place. This is the residue the
  append-only convention actively produces.

  The fix is a **discrimination**, not a new warning. `upload-asset.sh` pins the
  existing asset head for byte-identical reports and commits otherwise, so the
  asset URL moves **iff** the report did:

  | asset moved | meaning | behaviour |
  |---|---|---|
  | no | honest idempotent retry | quiet, **exit 0** — `unchanged` |
  | yes | report changed, composed body did not | `NOTHING PUBLISHED`, **exit 3** |

  Exit `3` is distinct from `1` so a caller can tell *"a step failed, retry it"*
  from *"nothing failed, nothing published, go and say it yourself"* — re-running
  this one unchanged reproduces it exactly. The stderr block names the
  append-only collision as the cause and gives three ways out. The action log
  records `comment=nothing-published`, so the distinction survives into what the
  orchestrator reads rather than living only on stdout.

  `test-ng-wrap-up.sh` previously **asserted the defect** — its own comment said
  *"the report gets materially corrected"* while requiring exit `0` and the word
  `unchanged`. It now asserts the corrected contract, alongside the pre-existing
  honest-retry control (same mock sha ⇒ still quiet, still `0`), so the pair
  discriminates rather than merely passing.

- **The merge-ref base check could report `current` from a round whose tests
  never ran, and a `current` verdict never said when it expired.** `#837`
  shipped `_merge_ref_base` with a named limit — *"if two runs at one head
  tested DIFFERENT bases, this reports the first one it finds"* — resolved in
  the DEFAULT-UNSAFE direction. Three separately-measured facts compose into a
  silent false clear: `actions/runs?head_sha=` returns **newest-first**, so
  "the first one it finds" is systematically the FRESHEST base;
  `conclusion=="success"` does **not** identify the run that supplied the
  verdict (`ci-signal` and `conflict-markers` fire unconditionally and DO print
  the checkout line); and later rounds routinely have `tests` **skipped** while
  a cheap workflow succeeds. So the check could read its base from a round whose
  suite never executed and report `Merge-ref base: VERIFIED`.
  The fix **stops picking**: every selected run is read, and a disagreement is
  its own fail-closed verdict (`divergent`, `ng ci-attempts` rc **10**) rather
  than a silent preference for the freshest. Identifying "the verdict run" is
  deliberately not attempted — it is not determinable from run metadata, which
  is how the gap arose; agreement makes the question moot and disagreement is
  reported, not resolved. The caller's gate changed from a **denylist**
  (`[[ $_MRB_STATE == stale ]]`, permissive default arm — under which
  `divergent` would have cleared the head while printing `NOT CHECKED`) to an
  **allowlist with a default-DENY arm** owned by the library
  (`_mrb_clearance_disposition`), so the next state added is fail-closed by
  construction.
  **The first cut of that fix contained the defect it was fixing**, found by an
  independent review pass and fixed here: "every selected run" was still a
  NEWEST-FIRST WINDOW OF EIGHT. On this PR's own head that window admitted eight
  cheap runs and excluded **both** runs that executed tests — `#882` verbatim,
  reachable by editing a PR description four times. Both caps (runs and jobs) are
  gone; a genuinely truncated API page (`total_count > 100`) reports `unread`,
  because a population nobody enumerated cannot support "they all agree". Every
  count now carries its **denominator** (`N of M`) — the first cut printed
  `8 successful run(s) read` where 8 was the CAP, and a bare count reads as
  completeness.
  Separately, a `current` verdict is **point-in-time** and nothing re-checked it
  between the verdict and the merge. Measured against ground truth — the base
  each run checked out versus the FIRST PARENT of the merge commit that landed —
  over **every** merge into `dev` in
  `[2026-08-10T00:47:22Z, 2026-08-14T17:18:41Z]` — from the merge that introduced
  the check to the last merge before CI failed repo-wide, measured
  `2026-08-14T18:53:54Z` against `dev` `e256d4a9865`: **5 of 17 (29%) landed on a
  base their green never tested** (`#870`, `#871`, `#890`, `#869`, `#899`).
  Windows of 5m00s, 8m10s, 19s, 15m42s and **4s**; every one a clean merge with
  no conflict and no red. (17 excludes `#837`, which introduced the check and so
  could not be gated by it; including it, 5 of 18. The range is stated because a
  rate without one cannot be checked or extended — three successively wider
  populations gave 1/6, 4/15 and 5/17, each larger than the last.) `ci-attempts` now prints the
  base sha **in full** beside the clearance with an explicit expiry sentence, so
  a caller can COMPARE rather than remember. `ng pr merge` grows two opt-in
  guards: `--base-sha <verified-base>`, and — because a **19-second** window is
  not something an agent can be instructed around — `--verify-base`, which runs
  the base check inside the merge verb milliseconds before the PUT, so there is
  no sha to carry and no interval to lose. Opt-in
  deliberately: a base check firing on every merge would block the board every
  time `dev` moved during a review, and a gate that always fires is a gate
  somebody disables. Both suites were ALSO blind to the layer the selection lives in: their stubs
  never evaluated `--jq`, so restoring `.[0:8]` *in the jq expression* left every
  assertion green — the fix was correct and completely unguarded. The merge-ref
  stubs in **`test-merge-ref-base.sh` and `test-ci-head-attempts.sh`** now serve
  GitHub-shaped JSON through **real `jq` with the real expression the library
  passed**, and that mutation is red in both. Counts DERIVED from the mutation
  harness rather than transcribed — restoring `.[0:8]` to the run-selection jq at
  `dff4873`, anchor verified to match exactly once and the tree verified clean
  before and after (`<your-org>/nexus-code#938`):

  ```
  clean    test-merge-ref-base.sh     59 passed, 0 failed
           test-ci-head-attempts.sh   ALL TESTS PASSED (50)
  mutant   test-merge-ref-base.sh     56 passed, 3 failed
           test-ci-head-attempts.sh   49 passed, 1 FAILED   <- witness: "878 boundary fixture"
  ```

  The caller suite fails on ONE named assertion, not two — and the earlier figure
  in this entry (`3 and 2 … 54/0 and 48/48`) was stale in three places at once.
  That is worth stating rather than silently overwriting: this entry describes a
  guard whose claim outran its measurement, and a hand-copied count in its own
  CHANGELOG is the same defect one layer out. Two residuals closed with it: the **jobs** page
  is bounded at 100 exactly as the runs page is (a truncated job list is now
  named, with its count, rather than absorbed into a bare shortfall — and a
  fixture now puts a checkout line in the **8th** job, so the job-side slice is
  load-bearing rather than merely absent), and a
  **non-numeric** `total_count` — what jq emits for an absent field — was
  **fatal**, not silent: under `set -u` (which `ci-head-attempts.sh` sets),
  `(( total_count > 100 ))` on `null` is `bash: null: unbound variable`, rc 127,
  measured on bash 4.4.20; without `set -u`, and under zsh 5.4.2 with it, the
  same expression returns rc 1 and passes silently. A crash on the live path, a
  silent pass elsewhere, a verdict in neither.
  Also: **all 75 value-taking flag arms in `monitor/ng` itself** now refuse a
  missing value instead of spinning the parse loop forever — `shift 2` with one
  positional left FAILS without shifting, reproduced in isolation at 2000+
  iterations with `$1` unchanged — guarded as a CLASS with a source lint (plus a
  planted-regression control, since a lint that matches nothing passes forever)
  rather than at the two arms a reviewer happened to name.

  **The first cut of that guard checked a PROXY, and its own suite said so for a
  day before anything read it.** `[[ -n "$2" ]]` answers *is the value
  non-empty*; it was read as answering *does a value exist*. Those agree on every
  instance anybody reported and diverge on a SUPPLIED EMPTY one — and
  `ng log-action --note ""` is a documented, tested caller of exactly that shape
  (`cmd_log_action` accepts it and omits the key via its `if $note != ""`
  branch). So the sweep turned a valid call into a hard error:
  `test-ng-log-action.sh` **26/2 on this branch, 28/0 on `dev`** — red since the
  sweep commit, and invisible because this PR's last CI verdict predates it. A
  gate that checks a proxy rather than the property is the defect one layer out
  from the one this entry is about, which is why it is closed as a class here
  rather than exempted at the one arm a suite happened to cover.
  Neither predicate alone is correct, and each failure mode is invisible from the
  other side: emptiness alone breaks `--note ""`; **arity alone lets `--sha ""`
  through, and an empty pin merges UNPINNED while reading as pinned** — the
  original S5 defect restored. `_need_val <flag> "$#" "${2:-}" [--allow-empty]`
  now asks both. Arity reads the CALLER's `$#`, which is precisely the condition
  under which `shift 2` succeeds, so the guard and the mechanism ask the same
  question instead of one standing in for the other. Non-empty is ON by default;
  `--note` is the single opt-out, spelled like the existing `bk_require_int
  --allow-empty` convention so a loosening is a visible per-flag decision.
  Three assertions added, each mutation-tested against a DISTINCT mutant probed
  at parse time — arity-only (`--sha ""` no longer refused), emptiness-only
  (`--note ""` refused), and `--note` unguarded, which **times out at rc 124**:
  the spinning parse loop this whole class is about, reproduced directly rather
  than described.

  The numbers name **what each command counts**, because the earlier phrasings
  did not and were narrowed three times for it — the sentence said *arms* while
  the number counted the `_need_val` **idiom**. At `dff4873`:

  ```
  # value-taking arms in monitor/ng               73 line-start + 2 single-line `case` = 75
  grep -cE '^[[:space:]]*(--[a-zA-Z0-9-]+\|)*--[a-zA-Z0-9-]+\).*shift 2' monitor/ng   -> 73
  # of those, guarded by the shared helper
  grep -c '_need_val --' monitor/ng                                                   -> 73
  # and by an inline check (cmd_respawn's --window/--workdir, which predate the helper)
  grep -cE '^[[:space:]]*--[a-zA-Z0-9-]+\).*\[\[ -n "\$\{2:-\}" \]\] \|\| die.*shift 2' monitor/ng -> 2
  # unguarded
  (arms matching neither)                                                             -> 0
  ```

  So: **75 arms, 73 via `_need_val`, 2 inline, 0 unguarded.** The earlier `68`
  and `72` were both real measurements of narrower things — the rewrite's own
  tally, and the helper idiom — quoted as if they described the arm population.
  (`#911` is the standing question that keeps catching this: a number is only as
  wide as the command under it.)
  The 75th arm is the argument for guarding a class rather than a list, and it
  arrived from OUTSIDE this branch: `--not-a-skeptic-verdict` (`#879`) landed on
  `dev` while this PR was open, unguarded, in the middle of the arm block this
  branch had just closed — a defect neither side contains, manufactured by the
  merge seam. Its author could not have seen the lint; the lint is precisely what
  sees it. Resolved with `_need_val` at the rebase; the class lint's planted-arm
  control was re-run against this tree to confirm it would have failed had it not
  been.
  **SCOPE, stated because the method is a single-file grep and the verb surface
  is larger:** this covers the arms parsed inside `monitor/ng`. `ng` DELEGATES
  many verbs to scripts under `monitor/`, which parse their own flags and are
  NOT covered. Measured over the `_facade` targets `ng` actually delegates to
  (14 scripts; `grep -oE '_facade [a-z0-9_.-]+\.(sh|py)' monitor/ng | sort -u`),
  at `dff4873`: **37 value-taking arms not using `_need_val`, across 8 of them** — `pane-state.sh`
  16, `paste-followup.sh` 7, `retire-preflight.sh` 5, `guards-for-diff.sh` 3,
  `lit.sh` 3, and one each in `ci-head-attempts.sh`, `reports-roll.sh`,
  `user-pat.sh`. **The predicate is "does not use `_need_val`", NOT "hangs"** —
  those are different populations and only the first is what the command counts.
  Two spin TODAY: `ng guards-for-diff --base` and `ng ci-attempts --repo`, both
  timed out at 12s by exactly the mechanism above; others refuse by other means
  (`retire-preflight.sh` guards all five of its arms with `shift 2 || usage`;
  `paste-followup.sh` uses neither idiom and still refuses at rc 1, measured).
  Naming the predicate rather than its consequence, because "unguarded" read as
  "will hang" and that is the same one-notch widening this paragraph exists to
  legislate against — the last instance of it, inside the paragraph that names
  it.
  (An earlier draft of this paragraph said *103 across 24 files*. That was
  measured with the pathspec `git ls-files "monitor/*.sh"`, which matches
  **464** files because git's `*` crosses `/` — **339 of them the test suite
  under `monitor/watcher/`**. A bare unreproducible number, introduced by the
  fix for a bare unreproducible number, in the entry about exactly that.) **`#924` owns that remainder** and is being
  fixed across `ng` and its delegated scripts; it is deliberately not touched
  here, to avoid colliding with that work.
  The overclaim was caught *because* the method was named beside the number —
  "every value-taking flag arm in `ng`" reads as universal, and running the
  command it cites is what showed it measures one file. A bare `72` would have
  read as authoritative and been uncheckable, which is the argument for carrying
  the command, demonstrated on the entry that adopted the practice; `--verify-base` reports `NOT CHECKED` rather than `OK` when
  the base could not be read (`permit` is not `verified`); and all three flags
  are documented in `docs/reference/ng-cli.md`, `skills/nexus.bot/SKILL.md` and
  `monitor/agent-prompt.md` — a flag nobody can discover is a flag nobody uses.
  Coverage — counts and the commands that produced them, because a bare number
  cannot be rechecked (`bash <suite>`, at `dff4873`, against `dev` `e256d4a`): `test-merge-ref-base.sh` 14 → **59** assertions
  (the suite previously had **no** case where two runs yield different bases,
  which is why the limit went unexercised, and no case where a head carries more
  runs than a cap admits), `test-ci-head-attempts.sh` 44 → **50**, `test-ng-pr.sh`
  81 → **129**, `test-ng-log-action.sh` 28 → **31**; every new arm mutation-tested, including a control that restores the
  `.[0:8]` window and confirms it clears a head whose only test runs sat at a
  stale base.
  Closes `<your-org>/nexus-code#878`, `#882`, `#880` (closed by hand on merge — `Closes #N` is inert on this repo).
- **A bare `ok`/`bad`/`pass`/`fail` in a suite exited 127 counted by NOTHING, so
  the suite reported success for a check that never ran** (`<your-org>/nexus-code#922`).
  The mechanism to catch this already existed — `command_not_found_handle` in
  `monitor/watcher/_test_helpers.sh`, with the `#805` ledger closing the subshell
  hole — but its **boundary was a NAME PREFIX** (`assert_*|th_*`) while the rule
  it states is "a missing assertion helper must fail the suite". `ok` is an
  assertion helper by function and not by spelling, so it fell through to the
  default arm. A boundary drawn narrower than its mechanism, which is the defect
  class the file exists to catch.
  Not hypothetical: the **headline assertion of `#881`** was written this way
  during `#907`. The suite went `222 -> 251 passed, 0 failed` with the one check
  the whole issue rested on silently absent, and the assertion-count floor could
  not see it — a 127 leaves no trace in the verdict **or** the count.
  **The added names are MEASURED, not guessed.** They are exactly the
  assertion-shaped names that some helper-sourcing suite defines locally and the
  helper does not export, which is the mechanism by which a name "looks
  available". At `e256d4a`, across the suites that source the helper (133 at `d102a7f`; the `143` first reported was a MENTION count — see `#939` F4)
  (`git ls-files -- 'monitor/**/*.sh' 'monitor/*.sh' | xargs grep -l
  _test_helpers.sh | wc -l`, cross-checked by shebang enumeration at 473 shell
  files): `pass` 14 suites, `fail` 14, `ok` 5, `bad` 4. **`pass` and `fail` are
  nearly three times as common as the two the issue named.** None is a real
  command on this host, so all four reach the handler.
  A **misspelled `assert_eqq` was ALREADY caught** by the prefix — measured, not
  assumed — so this widens the population rather than fixing the typo case.
  The negative control is load-bearing and preserved: an absent **binary** is
  still stock behaviour (127, no counted failure), because several suites invoke
  absent binaries on purpose.
  **What the runtime handler still does not catch**, stated because that is the
  whole lesson: a helper name that is neither `assert_*`, `th_*`, nor one of the
  four — a suite-local `expect`, `check`, `verify`. It can only fire for names
  somebody enumerated, and at call time an unknown missing name is
  indistinguishable from a deliberately-absent binary.

- **`make_gh_stub`'s generated stub read stdin to EOF on a GET with no piped
  body, hanging whenever the SUITE's own stdin was an open pipe**
  (`<your-org>/nexus-code#921`). The stub keyed on `[ -t 0 ]` — "stdin is not a
  terminal, therefore a body is coming" — which is a **proxy, and the wrong
  one**. Whether a suite hung depended on how the suite itself was invoked, so
  it presented as an intermittent flake that reads as "the runner was loaded".
  It cost ~40 minutes on `#900`, where a source mutation was the obvious suspect
  and was innocent.
  Fixed on the axis the mechanism varies on: **the verb decides**. Real `gh`
  reads stdin for `--input -` and nothing else, so the stub does too;
  `--input <file>` reads that file; every other invocation does not touch stdin
  and therefore cannot block on it. `--input` is split out of the `-H|-f` argv
  group and `-F` is now consumed (it was unhandled).
  **One deliberate, measured behaviour change:** a body piped *without*
  `--input` is no longer drained, so the writer sees SIGPIPE exactly as it would
  against real `gh`. The old stub drained unconditionally to prevent that.
  Reachability was measured before the trade was accepted — at `e256d4a` no
  production `ng` call site and none of the 10 `make_gh_stub` suites pipes a body
  without `--input` — and the behaviour is **pinned by an assertion**, so a
  future change re-examines the trade instead of meeting a mystery 141.

### Fixed (round 2 — `sk939` review of `#939`)

- **The `#922` sentinel was a pid-keyed file in the shared `/tmp`, and `#939`'s
  own new suite manufactured 7 of them per run** (`#939` F1, blocking). The
  sentinel is created by `command_not_found_handle` and removed only by
  `th_summary_and_exit`, so any process that trips the handler without
  summarising leaks one — and the new suite trips it deliberately, in `bash -c`
  children that never summarise. **67 had accumulated in `/tmp`.** With
  `pid_max` 36864 on this host, a leftover turns a later, *wholly clean* suite
  RED when the number comes round, with a diagnostic pointing at FAIL lines that
  were never printed. That is precisely the trade this PR elsewhere argues is
  the worse one — a harness that fails legitimate suites gets disabled — landing
  in the file 133 suites source.
  Three fixes, because cleanup alone only narrows the window: the 67 were
  **deleted** (ownership established by uid, exact pattern, dead pid, and an
  mtime window matching the authoring session — one had to be re-checked because
  its pid churned *between two checks*, which is the hazard in miniature); the
  suite now scopes `TMPDIR` for its children into `$WORK`, so their state lands
  where the existing EXIT trap already removes it (**not** a second trap — bash
  keeps one per shell and 121 of these suites own theirs); and the key is now
  **pid + process start time**, which cannot be reused, so a leak that does
  happen is litter rather than a landmine.
  The summary diagnostic no longer promises "see the FAIL lines above" — a
  message that sends a reader hunting for output that does not exist makes them
  doubt their own eyes rather than the harness.

- **The lint's implemented boundary was narrower than the one its header
  stated** (`#939` F2) — `#922`'s own defect reproduced inside its fix. The
  call-site regex required a first argument starting with a quote, `$`, or
  alphanumeric, so `ck -v "x"` and `ck /tmp/x` were missed *at line start, in
  command position*: inside the stated rule, outside the implementation. 2 of 7
  shapes caught. Flag-first and path-first are now matched (4 of 7). A **bare**
  call at end-of-line is deliberately still not, and the reason is measured
  rather than assumed: adding it flagged four sites in `test-remote-service.sh`,
  all of them Python's `pass` statement inside `python3 -c "…"` blocks, which
  heredoc-stripping does not reach. The residue is named in the header.

- **The lint claimed test coverage it did not have** (`#939` F3). A comment said
  the REFUSE arms were "exercised by the unit checks below"; **zero** assertions
  asserted rc 2. In a PR about checks that never ran being reported as checks
  that passed, that is the same defect at the documentation layer. The arms are
  now driven — a stub `git` makes the enumeration come back empty — with a
  negative control proving the same invocation is clean without the stub, and an
  assertion that a refusal (2) is not reported as a finding (1).

- **`143` was a MENTION count, not a SOURCE count** (`#939` F4).
  `grep -l '_test_helpers.sh'` matches comments and lint patterns too. The real
  population is **133 sourcing of 145 mentioning** at `d102a7f`; the 12 extras
  include `test-cc-auto-update.sh`, which states that it does *not* source the
  helper. The lint used the mention set and then treated the helper's exports as
  reachable in all of it — a soundness hole the population claim concealed.
  Detection now requires an actual source operator, allowing `&&`-chained and
  variable-indirect forms and paths containing spaces
  (`. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"` — a naive
  `[^[:space:]]*` path pattern under-counted 133 as 102). Every "143" in the
  code, tests and docs is corrected.

- **`#921` keyed on one SPELLING of the verb rather than the verb** (`#939` F5).
  `--input=-` is standard cobra syntax that real `gh` honours, and this repo
  already knows it (`monitor/gh-shim.sh` enumerates `--input|--input=*`). The
  stub matched only the space-separated token, so the attached form silently
  truncated the body capture and never read stdin — converting the old *hang*
  class into a *wrong-answer* class. Latent, not live: no current caller uses it.

### Added

- **`monitor/watcher/undefined-helper-lint.sh`** — the static half of `#922`,
  covering the general case the runtime handler cannot. It **derives** the
  cross-suite name population from the corpus instead of from a list: any name
  some helper-sourcing suite defines as a function, that the helper does not
  export, is a name that "looks available" from anywhere else.
  Clean at `d102a7f`: **133** suites, 457 cross-suite names, 9 real commands
  excluded, 38 exports, **0 offences** — an empty findings list, and a real
  answer: this is a recurrence guard, not a repair, because no suite currently
  carries the defect.
  **The false-positive work is the substance.** The first draft produced ~130
  false positives against that zero-offence corpus, which would have got the
  lint disabled by the first person under time pressure — removing it entirely.
  Four exclusions, each traced to a measured cause: real commands on PATH
  (`timeout` is a shim function in 7 suites, so every legitimate `timeout` call
  was flagged); sourced libraries resolved by **basename** (`wait_for` lives in
  `test-integration/_harness.sh`, reached through an unexpandable
  `"$_test_dir/..."`); heredoc bodies, stripped with the helper's own
  `th_strip_heredocs` rather than a second regex; and functions pulled in by
  extraction (`source <(sed -n '/^name() {/,/^}/p' …)`), which no path resolver
  can follow.
  Fails **loud** rather than clean when it cannot look (`#906` B): exit 2 REFUSED
  if the suite enumeration, the export parse, or the candidate derivation comes
  back empty. A checker that silently finds nothing is the same defect it hunts.


- **`run-tests.sh` could print a `FAIL`, report `0 failed`, and exit `0` — and
  on the `--jobs` arm CI actually uses.** The per-test rows come from `run_one`
  directly; the VERDICT is aggregated from per-job sidecars under `$run_dir`.
  Two independent channels, and the one that produces the exit code is the one
  that can silently lose its input. Measured on `dev` with `mktemp -p` failing:
  `0 failed`, `rc=0`, for a run in which **zero tests executed**
  (<your-org>/nexus-code#877).

  **What this closes, stated exactly.** Three channels are reconciled: what the
  runner DISPATCHED, what it RECORDED, and what it PRINTED. Not "the accounting
  and the verdict cannot disagree" — that was the original framing, it is a
  universal claim about a runner with more than two channels, and it was false
  as written. `<your-org>/nexus-code#887`'s skeptic reproduced `#877`'s exact
  symptom (`FAIL` row, `0 failed`, `rc=0`) on the *fixed* runner by selectively
  destroying an outcome sidecar: the record still reconciled against dispatch,
  the dispatcher still exited 0, and the printed row and the tally came from two
  separate writes in `run_one` five lines apart.

  That third channel is now closed too — the terminal record carries the STATUS
  beside the path, so the printed row and the verdict derive from one write, and
  the summary refuses when they disagree. Beyond those three, no claim is made.

  Three guards, and all are load-bearing:
  `run_one` now writes a terminal-accounting record for EVERY outcome and the
  summary refuses a clean verdict when fewer tests were accounted for than
  dispatched; and the parallel dispatcher's own exit status is captured instead
  of discarded. Three triggers were exercised — a refused `mktemp`, a run dir
  destroyed mid-run, and a child killed by a signal — and the run-dir case is
  caught ONLY by the dispatch status (its sidecars are annihilated along with
  the directory), which is why neither guard subsumes the other.

  The record is written ABOVE the outcome `case`, not per-arm, so an outcome
  added later cannot silently escape the count; and it is its own file rather
  than a quantity derived from the outcome sidecars, because `exit 77` (SKIP)
  writes no outcome sidecar at all — a naive "no sidecars means refuse" rule
  reddens a legitimately all-skipped run.

- **The fork-bomb guard lowered `RLIMIT_NPROC`'s HARD limit, irreversibly, and
  said nothing when it therefore could not engage.** `ulimit -u N` sets soft
  AND hard; only a privileged process can raise hard back. A NESTED
  `run-tests.sh` — which is exactly what `test-run-tests-bounded.sh` runs —
  inherited that ceiling, could not probe its own fork floor above it, skipped
  its own guard, and printed nothing, so `T6a` failed with `banner absent or
  wrong` and no way to tell why (<your-org>/nexus-code#863).

  The cap is now applied with `ulimit -Su` (soft only). Containment is
  unchanged, because the kernel checks `fork()` against the SOFT limit — the
  hard limit only bounded how far soft could be raised back, so the only thing
  the bare form added was the damage. Measured on the fix host with soft held
  identical at `1627` and only the hard limit varying: under the old soft+hard
  cap the nested guard's banner is ABSENT, under the soft-only cap it is
  present. A guard that declines to engage now says so on every path, since
  silence was the part that made the failure undiagnosable.
- **A full-screen select dialog classified as `state=empty` — "don't know yet" —
  so nothing in the control surface ever saw it.** `pane-state.sh` had an arm
  for each dialog anyone had enumerated (permission prompt, rate-limit menu,
  AskUserQuestion chip-bar, Bypass Permissions modal) and none for the shape
  they share, so any other dialog fell past every check to the input-row logic,
  found no `❯<NBSP>` chevron, and landed on the most ambiguous value available.
  `_unstick.sh` never fired (its `case_B` needs `blocked`), and a worker that
  would **never** proceed was indistinguishable from one that had merely not
  started, for as long as it hung. Claude Code 2.1.232 turned that from a
  rarity into every spawn: nested git repos stopped inheriting workspace trust
  from a parent, every `work/<project>` is a nested repo, so every worker booted
  into the folder-trust dialog and the whole board read as quiet
  (<your-org>/nexus-code#888 found it; `#896` is the classifier half).
  `_has_menu_dialog_frame` now detects the frame **structurally** — a
  navigation footer (`Enter to …` / `Esc to …`) in the bottom slice, a
  chevron-selected numbered option with at least one sibling above it, and no
  REPL input row below the footer — so a dialog nobody has enumerated is still
  seen. `overlay=<kind>` carries the naming separately (`workspace-trust`, or
  the honest generic `dialog`), which is the seam that keeps detection
  independent of wording; blinding the naming table leaves the live capture
  `blocked`, and the suite asserts it. The previous instance of this class
  (`#768`) was closed with two text literals, which is why this one cost
  another release cycle to find. Nothing auto-answers it: `_unstick.sh` runs its
  own text-keyed detection and no arm matches, so a security prompt is
  **surfaced**, not silently confirmed. Widening `blocked` takes nothing off
  `bk_pane_kill_authorized`'s allowlist — `empty` was already refused as
  indeterminate and `blocked` is refused as active — so the change moves a pane
  from one refusing state to another. Regression cover: a fixture **captured
  from the live binary** (not transcribed from a PR body) plus
  `test-realmodel-trust-dialog.sh`, which re-derives that capture from the real
  binary on every gate run with a trusted-parent control arm, so the committed
  copy cannot rot into fiction. `test-pane-state.sh` 156 → 188 assertions:
  one dialog whose wording exists nowhere (the class assertion), four near-miss
  panes each failing exactly one condition, a sweep proving `overlay=` appears
  on exactly the `blocked-*` fixtures and no others, and a mutation per
  condition against the pane only that condition rejects. It also gave the six
  `working-background-*` fixtures a prefix arm — they had none, so the loop
  silently SKIPped them and six committed captures were asserting nothing.

- **`--not-a-skeptic-verdict` cleared the opting-out window's OWN
  skeptic-pending marker, letting a window discharge a verdict it genuinely
  owed** (`<your-org>/nexus-code#879` F1, found by the post-hoc skeptic on `#907`).
  The opt-out falls through to the producer path, and three producer branches
  `rm -f "$pending_dir/${sw_safe}"` — `denied-spawn` (spawn mode `deny`),
  `denied-auto` (`--skeptic-decision deny`) and the operator waive. `sw_safe` is
  the opting-out window itself, so a window whose marker was seeded when a
  depth-2 skeptic was spawned against it could clear that obligation by
  declaring "this wrap-up is not a verdict", and `retire-preflight.sh` flipped
  `safe=0` to `safe=1`.
  **Strictly worse than the defect `#879` fixed:** it converts a *forced false
  verdict*, which is visible in the record, into a *silent absent* one, which is
  not — and it lands in the gate every retirement decision is made from.
  The verb, `monitor/README.md` **and** `skills/nexus.skeptic/SKILL.md` all
  stated that no skeptic marker is cleared, so three documents asserted the
  opposite of the code. **The code moved to meet the documents**, because the
  documented behaviour is the correct one: an opt-out is a statement about *this
  hand-off*, not a release of a *pending obligation*. All three removals now go
  through one `_sk_keep_own_marker` helper — centralised rather than inlined
  three times, since the bug *was* three sites and a guard that must be repeated
  is a guard that gets missed on the fourth — which suppresses the removal under
  the opt-out and prints `SKEPTIC MARKER KEPT`. The waive is guarded too: the
  promise as written is unconditional, and the error directions are asymmetric —
  a marker wrongly kept is a blocked retirement the operator can see, a marker
  wrongly cleared is a silent false release. Controls assert an ordinary
  spawn-deny and auto-deny still clear the marker, so the guard cannot become a
  board-wide retirement block.
  The original test could not have caught this: it asserted the *stamped
  target's* marker under `mode=require` — the one producer branch that writes a
  marker rather than clearing one. Wrong axis, wrong mode.

- **The orchestrator-facing `recommendation:` line claimed "derived from a
  findings COUNT" on the producer path, where no count exists** (`#879` F2). The
  `#881` fix taught that line not to describe an absence as a measurement, but
  applied it to the role path only; the arm is reached from both. On the producer
  path `derived` is `require` and comes from the window's **spawn mode** — no
  count is consulted at all, so the sentence named a computation the verb does
  not perform. Same defect one arm over: a derivation named after the wrong input
  is no more true than an absence named as a measurement.

- **`docs/reference/ng-cli.md` never learned `--not-a-skeptic-verdict`**
  (`#879` F4, `#883`'s class). Added to the synopsis and the skeptic-gate prose,
  along with the `#881` semantics for `--skeptic-findings`.

### Corrected

- **The `#881` retrospective was over-claimed and is retracted in part.** It
  reported that the historical defaulted-vs-supplied `findings` split is
  *unrecoverable*. Scoped to the **action log** that is true and stands — 335 of
  338 records carry a byte-identical key set. Extended to "no artefact on disk",
  it is **false**: the reports corpus classifies roughly a quarter to a third of
  the population, because skeptic reports often state their own count in prose
  (`sk907`: 99/338; independent re-measurement: 82/338 — the two disagree sharply
  on composition, 58/41 vs 76/6, so the *direction* of the split remains
  unmeasured and should not be quoted). Retraction on `#881`, correction in the
  `#907` PR body.
  The instructive part is the failure mode, not the number: **"unrecoverable"
  was the reassuring answer** — it closes a question rather than opening one, so
  nobody re-tests it. The narrow claim was rigorous and the broad claim inherited
  its credibility without inheriting any of its evidence. `#907`'s own report had
  already named the reports corpus as the untested avenue and published the
  absolute claim anyway. A negative result must be scoped to the evidence that
  produced it, **in the sentence** rather than in a caveat further down.

- **`ng wrap-up` recorded an OMITTED `--skeptic-findings` as a measured `0`,
  and fed that number to the gate that decides whether a second skeptic pass
  is warranted** (`<your-org>/nexus-code#881`). `[[ -n "$findings" ]] ||
  findings=0` is the sibling of `#601` and the one `#601` left standing:
  `#601` stopped an *unreadable* value becoming the one value that means
  "nothing found", and the very next line did it to an *unstated* one.
  `bk_require_int --allow-empty` preserves the empty-vs-invalid distinction
  deliberately; the default discarded the surviving half. Downstream the
  fabricated zero was consumed as an observation — printed as
  `new findings : 0`, logged as `"findings":"0"`, compared against the
  recursion threshold — so *"the skeptic measured zero new issues"* and
  *"the skeptic never said"* became one record. The repo's own dominant
  defect class, absence rendered as a measurement, living inside the
  machinery that adjudicates the other instances of it.
  **The historical population is unrecoverable and that is stated rather
  than papered over.** Measured on one operator's log: 338 of 615
  `skeptic-verdict` records carry `findings=0` and NOT ONE can be
  classified — two hermetic wrap-ups differing only in whether the flag was
  passed emit byte-identical records across *every* event the verb writes;
  `ng` logs no argv, the `wrap-up` event carries no count, and nothing else
  under `.state/` holds the invocation. Records predating `#601`
  (2026-07-30) are three-way ambiguous, since prose also coerced to `0`.
  **The fix carries absence as absence — no sentinel.** A `-1` would be the
  same defect in a new costume, because a consumer can do arithmetic on it
  without noticing nobody supplied it. Unstated now prints
  `new findings : not stated`, logs `findings-stated=false` with **no**
  `findings` key (and `findings-stated=true` alongside a real count, so the
  distinction is a positive assertion on disk rather than a missing field),
  and the threshold comparison is simply **not reached** — unguarded,
  `(( findings >= thresh ))` on an empty string is not even an error in
  bash, it silently answers "below threshold" for a count never taken.
  With **neither** a count nor a readable `disposition:`, wrap-up now
  ESCALATES instead of terminating: nothing is on record saying the chain
  may end, and `#678`'s own point 4 is that a blank statement is the case
  that should ask. Every terminal message distinguishes the two — a
  `no-further-pass` with no count terminates on the *disposition*, and says
  so, instead of claiming "no substantive new issues" over a measurement
  that was never made. A legitimate clean pass is unchanged: an explicit
  `--skeptic-findings 0` still terminates the chain silently and cleanly.
  29 assertions in `monitor/test-bookkeeping-contract.sh`, which asserts
  the two states are DISTINGUISHABLE rather than checking either against a
  value — a test asserting `findings == 0` after an omission would pin the
  bug, which is roughly how it survived `#601`.

- **A skeptic-stamped window could not wrap up worker work without asserting
  a skeptic verdict it had no basis for** (`<your-org>/nexus-code#879`). The
  role is derived from the window's *provenance* record (`skeptic_role:
  true`), and a window is stamped for its lifetime rather than for one task.
  A retained skeptic that later authored a patch therefore met
  `--skeptic-role requires --skeptic-verdict ...` on a wrap-up that was not
  a verdict, and no flag meant *"this is not one"* — so the only way to
  complete the documented hand-off was to supply a verdict on its own diff.
  That is worse than refusing: a self-review is indistinguishable
  downstream from an independent clearance, and the verb was therefore
  manufacturing the exact artefact the skeptic protocol exists to prevent.
  The workaround on the board (hand-rolled `ng upload` + comment) skips the
  `report-check` pre-flight, the templated link comment and the action-log
  `wrap-up` event the window-cleanup loop reads, so the window looks
  un-wrapped.
  New **`--not-a-skeptic-verdict "<why>"`**: takes the ordinary producer
  path, so the window's own work gets the normal skeptic decision for its
  spawn mode, and records `skeptic-role-not-asserted` with the reason. The
  reason is mandatory and substantive (>=20 chars, the
  `GH_IMPERSONATE_REASON` shape) — an opt-out nobody has to justify is a
  way to dodge an obligation. It **discharges nothing**: no skeptic marker
  is cleared, so a verdict the window owes is still owed and its target
  stays blocked. Mutually exclusive with `--skeptic-role` and
  `--skeptic-verdict` (refused at parse time, before the upload, so a
  contradiction cannot strand a half-completed hand-off), and refused
  outright on a window that was never stamped. The original refusal now
  **names the escape hatch** — a refusal whose only open path is the false
  one is what produced the fabricated verdicts. 17 assertions in
  `monitor/watcher/test-skeptic-channel.sh`, which also gains the
  assertion-count floor it lacked, plus 7 parse-time assertions in
  `monitor/test-bookkeeping-contract.sh`.
  **Checked against `#906`(A) before adding the flag**, since that finding
  raises the possibility that `#879` is `#883`'s class — a correct mechanism
  behind a lying interface, where the fix is to advertise rather than add.
  Measured at `origin/dev`: all **ten** pre-existing `--skeptic-*` flags
  refuse a stamped window doing worker work, and exactly one thing completes
  the hand-off — asserting the verdict. Structurally, the role path is
  entered on provenance and has one exit; every other flag is read in the
  producer path (unreachable from there) or decorates a verdict rather than
  substituting for one. The mechanism was genuinely missing.

- **`ng wrap-up --help` advertised NONE of the eleven `--skeptic-*` flags it
  parses** — wrap-up's share of `<your-org>/nexus-code#906`(A)/`#883`. This is
  not cosmetic for `#879`: a caller cannot consult a flag it cannot see, so an
  unadvertised escape hatch is not an escape hatch, and "assert a verdict"
  read as the only way out of the role gate. `_usage_for cmd_wrap_up` was a
  hand-written string; it now carries the whole family, grouped producer-side
  vs skeptic-side, with the `#881` note on `--skeptic-findings`. Scoped to
  this verb — the rest of `#906`(A) is untouched and not claimed.
  A drift guard keeps the hand-written string honest by extracting the arg
  loop's `--skeptic-*` arms and asserting each appears in `--help`. Per
  `#906`(B) — `#900`'s derived synopsis degraded *silently* on an arm it
  could not parse — the guard **refuses to be vacuous**: it asserts the
  extractor found >= 12 arms before comparing anything, and fails with "it
  did NOT run" otherwise. An extraction that returns nothing is not evidence
  of no drift; it is evidence the extractor did not run. Mutating the
  extractor's anchor to match nothing is one of the ten mutations run against
  this branch's assertions.

- **`monitor.cc_auto_update.tracking_issue` took a bare `N`, which resolves
  against whichever repo the consumer supplies — so a run of evaluations posted
  to an unrelated closed PR and was never seen.** `#N` is repo-relative.
  `CLAUDE.md` already warns about this for comment BODIES, where GitHub renders
  the link and the ambiguity is at least visible; in a **config field** nothing
  renders it, so the repo is supplied invisibly at the point of use. The
  evaluator prompt pairs the value with the *surface repo* (the implementation
  repo every operator clones), so a number written against an operator's own
  asset repo was read against the shared one. Nothing errored — the number
  resolved, the API returned `201`, the comments posted; the operator was
  watching a different `#N`.
  The fix is a **qualified reference**, `owner/repo#N`, not a corrected number:
  a corrected number is right until the next reader supplies a different repo,
  and is then wrong again with no more warning than before. Only a reference
  that carries its repo is stable under being read from anywhere.
  **Resolution now REFUSES rather than guesses**, because guessing is what
  produced a plausible target for a month. New `monitor/issue-ref.sh` parses a
  qualified reference (exit 0), reports *not configured* separately (exit 3),
  and refuses anything else (exit 4) — bare `N`, half-qualified `repo#N`,
  leading-zero numbers, issue `0`, and a pasted issue URL (for which it prints
  the exact config-form translation). `config/load.sh --validate` refuses the
  same shape at config load; the cc-update evaluator **declines to fire** and
  records `refused-unqualified-tracking-issue` in `decisions.tsv` rather than
  posting to a guessed repo — a skipped evaluation is visible on the next fire,
  a misrouted one is invisible forever. A **missing** resolver is also a
  refusal (absence of the checker is not evidence the reference is fine); an
  **empty** value skips it entirely (nothing to get wrong). The prompt now
  carries `TRACKING_REPO` beside `TRACKING_ISSUE` so a qualified reference is
  used against *its own* repo instead of being re-paired with the surface repo.
  **Second instance documented:** `monitor.remote.endpoint_issue` is the same
  shape, mitigated by an explicit `endpoint_issue_repo` companion — but its
  default resolves to the operator's **asset** repo while cc-update's resolves
  to the **implementation** repo. Opposite defaults, neither stated where the
  value is typed, so a convention learned from one field is silently wrong
  about the other. Both fields now say so.
  The discriminator worth carrying forward is not "resolves against an implied
  context" — nearly every config value does. It is **resolves against an
  implied context AND fails silently when that context is wrong**: a wrong tmux
  window identifier prints `no such tmux window`; a wrong issue number returns
  `201 Created`.

- **The worker floor's blanket force-push ban told every worker to refuse the
  rebase the merge gate requires (`#835`).** Two standing rules could not both
  be satisfied on a personal PR branch: the floor said *"never force-push"*,
  flat, while the merge gate requires the branch be rebased onto the **current**
  base before merge — and a rebase makes the push non-fast-forward. The gate is
  not negotiable: a `pull_request` run is computed against a merge ref built at
  **run creation**, so if the base moves afterwards a later green describes a
  tree that no longer exists, and `rerun-failed-jobs` **reuses that same stale
  ref**, so a later green can describe a base that has moved. (An earlier
  version of this entry said "only a NEW HEAD re-evaluates". That was
  **REFUTED by experiment**: the merge ref is **demand-triggered** —
  `refs/pull/N/merge` is recomputed when something asks GitHub for the PR's
  mergeability, and not otherwise. Measured: two refs sat stale for **26 and 36
  hours** across many base advances, while one refreshed within **two minutes of
  a single `GET /pulls/{n}`** and an untouched control did not move. So "it has
  been a while, it must have refreshed" is false, and **querying the PR
  refreshes it — the act of checking changes what you are checking**. Query the
  PR, then create a new run, then enumerate that run. The carve-out itself is
  unaffected: a rebase still makes the push non-fast-forward.) `#823`
  merged on exactly such a green and turned `dev` red across six of six
  unit-suite bands, and `#826` hit the contradiction directly, requiring the
  operator to authorise the force-push by hand, per worker.
  The floor now carries only the **boundary**, in one sentence: never
  force-push a *shared* branch (`dev`, `main`, or any branch carrying another
  author's commits); force-pushing your *own* PR branch after rebasing it onto
  the current base is expected. The runnable half — the checkable precondition,
  the `--force-with-lease` caveat, and the merge-ref rationale — moves to three
  new `force-push` rows in `bash-footgun-patterns.conf`, delivered by
  `bash-footgun-guard.sh` at the instant the worker runs `git push`.
  **The precondition must key on the PROPERTY, not on AUTHORSHIP**, and the
  first version of this change got that wrong. It shipped
  `git log --format='%an' origin/dev..HEAD | sort -u`, glossed as "if this
  lists only you, no other agent has commits here" — which is false *in this
  workspace, for a reason the same floor states two clauses earlier*: `git
  commit` / `git push` use the operator's identity, so every agent commits as
  the same author and the check cannot see a sibling at all (18 of the last 25
  `dev` commits are one name). Measured on a two-agent branch, it returned one
  name, read SAFE, and the force-push destroyed the sibling's commit and its
  file. `--force-with-lease` did **not** backstop it: the lease is satisfied by
  the very `git fetch` that rebasing onto current `dev` requires, and the push
  went through as `(forced update)`. The shipped check asks what would be
  overwritten — `git log --oneline <branch>..origin/<branch>`, run **before**
  the rebase (after it, a rebase has rewritten the remote's commits out of
  `HEAD`, so it always reports commits) — with
  `--force-with-lease=<branch>:<sha-you-saw-before-fetching>` as the pinned
  alternative. Caught by the `#835` skeptic pass.
  **That correction then had to be corrected**, by the same skeptic on the
  delta, for the same underlying reason one costume further on: shipped as
  prose, the property check was right whenever it could look and **silently
  safe whenever it could not**. Three states print empty — the branch is not on
  the remote yet, the fetch **failed**, or the tracking ref is stale because
  the fetch was skipped — and the first two are byte-identical at the terminal
  (same empty stdout, same `rc 128`, same stderr shape), so a failed fetch
  renders exactly like the all-clear. It is now **`monitor/force-push-check.sh`**:
  one command that fetches and compares together (so there is no step to skip,
  and no stale tracking ref to read), failing CLOSED with
  `guards-for-diff.sh`'s `#803` exit-code shape — `0` safe, `1` UNSAFE with the
  commits listed, `2` REFUSED (could not check, explicitly **not** a
  clearance), `3` no such remote branch (known, and distinct from `2`). Pinned
  by `monitor/watcher/test-force-push-check.sh`, whose fixtures are real repos
  with real remotes because the states being separated are git's own — including
  a control asserting the author check *would* have cleared the unsafe one.
  **And then a third correction, a false SAFE rather than a refusal**: the
  script compared `HEAD`, but a push moves `refs/heads/<dst>` on the remote from
  `<src>` locally, and **neither is necessarily the checked-out branch**.
  Measured: local `feature` lacking a sibling commit while `HEAD` sat on
  `integration` which contained it printed `SAFE rc 0`, and the push then
  reported `(forced update)` with the sibling gone. It now resolves what the
  push will actually move — `<branch>`, `<src>:<dst>`, or `push.default` +
  `@{upstream}` — and refuses rather than guessing for `matching`, `nothing`,
  and a detached `HEAD` with no ref given. Pinned by four ground-truth cases
  that ask the script, then perform the **real** forced push and check whether
  the sibling commit survived: a SAFE verdict followed by a lost commit is the
  failure. Against the pre-fix script those cases are 3/9 with two false SAFEs.
  Worth recording as a method rather than three bugs: authorship that could not
  detect a sibling, a check that could not tell "nothing to destroy" from "I
  could not look", and a check that compared the wrong ref — three levels, each
  fix opening the next hole, and **every one found by building the failing case
  rather than by reading the code**.
  **And then a fourth, on a fourth axis: the wrong REMOTE.**
  `remote.pushDefault` and `branch.<n>.pushRemote` select the push remote; the
  check assumed `origin`, said SAFE, and the push destroyed a commit on the
  other remote. At that point the diagnosis stopped being any individual fix:
  every round had been **re-implementing a piece of git's own push-target
  resolution** — `push.default`, `remote.pushDefault`, `branch.<n>.remote`,
  `branch.<n>.merge`, `branch.<n>.pushRemote`, explicit refspecs, `+` markers,
  `--all`, `--mirror`, per-remote push refspecs — a surface larger than anyone
  enumerates in advance, so each fix relocated the hole rather than closing it.
  The check now **asks git instead of modelling it**:
  `git push --dry-run --porcelain --force <the caller's own arguments>` reports
  exactly which refs would move on which remote, authoritative by construction
  because it **is** the resolution. The hand-rolled resolver is deleted; a test
  asserts no push-target config is re-derived. Side effects: multi-ref pushes
  (`push.default=matching`, `--all`, `--mirror`) became **answerable** instead
  of refused, and deletions (`-`) and unknown porcelain flags now fail closed.
  Residual named rather than left to be found: TOCTOU, network required (an
  unreachable remote is REFUSED, never a pass), server-side hooks not consulted
  (errs safe), and it reports what a plain `--force` would do, so a real
  `--force-with-lease` may be refused where this said UNSAFE — never the
  reverse.
  Two follow-ups from the round-five pass, neither a correctness defect but
  both fixed rather than deferred, because a residual is something that
  *cannot* be fixed and these could. **The two fail-closed arms were
  untested** — `!` (rejected) and the unrecognised-flag default arm had no
  assertion, so deleting either would not have reddened the suite: the same
  decoration-not-guard shape as the vacuous `\p` assertion earlier in this
  PR. Both are now exercised and mutation-checked; removing either arm makes
  the suite report a **false SAFE**. They need a PATH-front `git` stub because
  a live rig cannot reach them, and the reason is itself now measured and
  recorded: **receive-side policy is invisible to the dry-run** —
  `receive.denyNonFastForwards` and pre-receive hooks are enforced when the
  remote *receives*, so such a push is still reported `+ (forced update)` and
  classified UNSAFE. A false ALARM, never a false clearance, and pinned by a
  test because "errs safe" is a claim like any other. **And the check made two
  remote round trips** — the dry-run ran twice, once per stream, doubling
  latency and *observing the remote twice* so the two runs could disagree
  (the URL came from the second). Now one invocation with stderr captured via
  a temp file; measured 2 → 1 with an invocation counter. That split is the floor's own stated
  design principle applied: the floor is prepended to EVERY spawn prompt, so a
  rule with a hookable trigger belongs at the trigger, not in the preamble.
  Three implementation details are load-bearing and are now pinned by tests.
  Coverage is three rows, not two: `--force*`, an order-insensitive
  `-[a-zA-Z]*f` (clustered `-uf` is a real forced update and used to miss), and
  `[[:space:]]\+` for the `+refspec` forms — `git push origin +dev` **is** the
  forbidden act and drew no warning at all. The hook also now accepts `\p` as a
  literal `|` in a regex field, which is what lets the exclusion classes read
  `[^;&\p]`; without it `git push origin main | grep -f pats` matched on
  *grep's* `-f` and, first-match-wins, cost the worker its cwd-pinning
  reminder. That `\p` assertion was itself **vacuous** as first written: its
  example piped into `grep`, and unsubstituted `[^;&\p]` excludes the *letter*
  `p`, so grep's own `p` blocked the match and the test passed whether or not
  `\p` worked. The example is now `xargs` (no `p`); deleting the substitution
  takes the suite to 31/1 where it previously stayed 32/0.
  The force-push rows must PRECEDE the generic `git-push` row, because the hook
  takes the first match and the generic regex matches every force-push too —
  with the order wrong, a force-push silently receives the cwd-leak reminder
  instead of the boundary (no error, no failing match, just the wrong advice at
  the one moment it matters). The conf's `|` field separator forbids alternation
  in the regex field, so `--force*` and `-f*` are two rows sharing one tag; the
  tempting single-regex form `[[:space:]]-[-]*f` also fires on `--follow-tags`.
  And the precondition survives as a pipeline only because `message` is
  `read`'s LAST field, which absorbs embedded delimiters intact.
  The blanket ban is also removed from `CONTRIBUTING.md`,
  `docs/contributing/development.md`, `docs/operating/spawning-workers.md`,
  `docs/admin/repos.md`, `docs/reference/skills.md`, `README.md` and
  `nexus.tmux-spawn`, so the contradiction does not survive one file over.
  Branch protection on the shared branches is what makes the narrowed rule
  structural, and `docs/admin/repos.md` now says so.

- **`skills/**` matched no workflow `paths:` filter, so the highest-blast-radius
  edit in the repo ran NO tests (`#835`).** `test-spawn-worker.sh` EXECUTES
  `skills/nexus.worker-defaults/SKILL.md` as a fixture — it extracts the
  `## Worker floor` body and asserts its content, because that body is injected
  verbatim into every future worker's prompt. But `skills/**` appeared in no
  workflow filter, so a PR editing ONLY the floor triggered no `tests` run at
  all, while `gh pr checks` showed the by-construction-green `ci-signal` and
  read as "all checks passed" (`#604`). Same class as `#736` and the reason
  `CLAUDE.md` was added to this filter. `lint-workflows.py`'s PF rule did not
  catch it and was not wrong to miss it: `spawn-worker.sh` reads the floor
  through a runtime variable, and PF explicitly scopes itself to statically
  resolvable `run:`/source edges. Found while adding the floor's own force-push
  assertions — which were themselves unreachable on the PRs that would need
  them.

- **The autosuggest ghost-text detector matched a dim BOX BORDER, so one
  cosmetic renderer change would have turned every idle pane on the board into
  `autosuggest-only` at once (`#801`).** `_detect_dim_run` asked whether a faint
  (SGR 2) run carried a visible character, searching `${input_row#*❯}` —
  everything after the chevron **to end of line**. A dim closing border is
  exactly that. Measured, not reasoned: an empty input box rendered
  `…❯<NBSP>\x1b[7m \x1b[0m   \x1b[2m│\x1b[0m` classified `autosuggest-only
  input=ghost` for 28 s of deterministic polling, and `state=idle` was
  **unreachable** for that renderer. Claude Code does not draw that border today
  (9 of 9 idle captures carry no dim run after the chevron; its rules are
  `\x1b[38;5;244m`, not a whole-parameter 2) — the guard's correctness rested on
  a cosmetic property of somebody else's renderer that nothing checked and
  nobody owned. `_strip_dim_box_chrome` now erases dim runs whose entire visible
  content is box chrome, and **both** dim-keyed readers run through it.
  The second reader is the dangerous one and was not in the filed report:
  `_input_row_typed_text` cuts the row at its first dim run, and a dim **left**
  border precedes the chevron, so the cut takes the chevron with it. Measured on
  the new fixture, a vim-INSERT pane holding **real operator text** with no
  bright marker read `state=autosuggest-only input=ghost` — a kill-authorised
  state, and the token that tells an orchestrator the text is model-generated
  and safe to paste over. It is the operator's.
  Also fixed in passing, surfaced by that fixture: the vim-INSERT refinement set
  `state=user-typing` but left `input=` at whatever the pre-refinement detectors
  said, publishing `state=user-typing input=blank` — "a human is at this
  keyboard" and "the box is empty, paste away" on one line. It now says `typed`.
  Narrows a permissive answer; widens nothing.
  **Skeptic F1 (`#827`), material:** the first strip was a single `s///g` pass
  whose branch consumes the terminating ESC, so `g` resumed after that byte and
  ADJACENT dim runs were stripped alternately — one survived, and a surviving
  dim run carrying a visible character is `#801` intact. Measured: a DOUBLED
  border reproduced both halves. Closed with a `sed` label loop (`:a … ;ta`),
  which re-runs from the start of the line until nothing more matches.
  The deeper finding is the boundary, not the loop: `input-box-chrome.manifest`
  was offered as *the* coverage boundary while bounding only the GLYPH axis,
  and the mechanism also varies on RUN STRUCTURE (how many dim introducers the
  renderer emits across the border). A bound that is honest, tested, and drawn
  on the axis the SEARCH varied on rather than the axis the MECHANISM varies on
  is still false. The manifest now names both axes and points at the two
  adjacent-run fixtures that pin the second; the `#801` block mutant-tests all
  five.
  Coverage boundary is **data**: `monitor/watcher/input-box-chrome.manifest`
  carries a disposition per glyph, executed by `test-input-box-chrome.sh`. ASCII
  `|` and `+` are deliberately **content**, so an ASCII-art border is a recorded
  gap rather than a surprise; `■` (U+25A0) and `⓿` (U+24FF) sit one codepoint
  outside the two implemented ranges and go red if either quietly widens. Three
  fixtures pin the classifier itself — negative (empty box + border → `idle`),
  positive (real ghost bytes + border → still `autosuggest-only`), and
  kill-axis — plus a mutation that neuters the strip and asserts all three
  collapse, so the assertions cannot pass for an unrelated reason.

- **The watcher told the operator to relaunch a live agent that was waiting on a
  question (`#808`).** `_idle_probe.sh` maps `absent|blocked` to one
  `pane-absent` class, which is right — both need the operator — but the
  advisory described only the `absent` half: *"claude process gone or
  unresponsive; relaunch or close"*. A `blocked` pane is **alive** and rendering
  a modal only a human can clear. Observed in production 2026-08-07 22:49
  against window `idflake`, which was displaying an AskUserQuestion: five
  operator probes returned `state=blocked overlay=askuq` with `pane_pid`
  unchanged throughout, and the surface said the process was gone. Relaunching
  destroys a live agent's context and discards the question it is asking.
  The advisory is now per-state. The kill gate had held throughout
  (`bk_pane_kill_authorized` refuses `blocked`; `retire-preflight.sh` carries an
  explicit do-not-kill arm), so this is stated as a **trust** defect, not a
  safety one — the expensive outcome is an operator learning to discount
  `pane-absent`, a surface documented as inviolable and never suppressed.
  Second half, and the reason a classifier-only fix would have been invisible:
  the renderer's `pane-absent` arm printed a **fixed string and discarded `$4`**,
  so the advisory was decided in one file and overwritten in another. Every
  other class in that renderer already read `$4`. It now does too, falling back
  to the historical wording when the column is empty.
  Two documented contracts were stale and are corrected with it: the module
  header still claimed `state ∈ {absent, empty, blocked}` long after `empty`
  stopped mapping here, and `monitor/README.md`'s class table carried the fixed
  advisory as if it were the only one. Out of scope, and said so rather than
  silently: `n_pane_absent` in the summary line still counts both states into
  one number.
  Coverage: the existing suite asserted the **class** and passed throughout the
  incident; it now asserts the **string**, in both directions — `absent` keeps
  the relaunch advisory and must not acquire the blocked one, so "make
  everything say the blocked thing" fails. The blocked negative probes for
  *"claude process gone"*, not *"relaunch or close"*: the corrected wording ends
  *"do NOT relaunch or close"* and contains that phrase, so the obvious
  assertion flags the fix as the defect (it did, on the first draft).

- **`remote-up`'s port-collision guard refused to start over a peer that was
  already gone, and its refusal contradicted itself in its own text (`#810`).**
  The guard observed the port occupied, verified ownership with an ssh-keyscan,
  and then refused on the strength of the **first** observation — two
  observations of a mutable fact, so a run aborted with `nothing was registered
  or started` while printing `Connection refused` and `no LISTEN socket visible`
  about the same port. Seen in CI on `#795` under `cpu-stall%=58.47` on 2 vCPUs,
  which widens the gap between the two.
  Fixed on the property rather than the proxy, in two halves. **Occupancy is now
  answered by an actual `bind()`** (`_remote_port_bindable`, SO_REUSEADDR +
  `listen()` so it mirrors what sshd does) — a connect answers a different
  question and is wrong in *both* directions. That is not theoretical here: the
  new suite measures, on this host, a port held as an ESTABLISHED outbound
  **source port** answering the connect probe "free" while `bind()` gets
  EADDRINUSE. `#769`'s defect was live in this guard too, un-filed, in the
  direction that reintroduces the EADDRINUSE-backoff-forever state the guard
  exists to prevent. **And every refusal now re-establishes its own premise**: a
  port that is bindable at verification time is not holding anything.
  This cannot weaken the guard — the proceed arm fires only when we have just
  bound the port ourselves, an inconclusive probe (no python3, unbindable
  address) leaves the refusal standing, and the three connect/`ss` signals
  survive as the no-python3 fallback so such a host keeps the previous
  behaviour exactly. The residual race is **declared, not papered over**: a
  third party may bind between the probe and the sshd bind. Closing it outright
  means handing sshd a pre-bound descriptor, which `sshd -p` cannot accept; when
  it is lost, the supervisor reports EADDRINUSE and the identity-aware
  healthcheck surfaces it.
  Every now-proceeds case in the new suite is paired with a real-listener case
  that must still refuse and a probe-cannot-tell case that must still refuse,
  because "stop refusing" is trivially achievable by disabling the guard. The
  suite never registers, starts, or binds the `nexus-remote-ssh` service.

- **The CI-enumeration recipe checked WHICH runs and WHAT they concluded, and
  never AGAINST WHAT BASE (`#823`).** A `pull_request` run does not test your
  branch: it tests `refs/pull/N/merge`, a merge commit GitHub computes **at run
  creation**. If the base branch moves afterwards, every green stays green while
  describing a tree that no longer exists. `#823` merged on exactly that, and
  the enumeration that cleared it was **correct about everything it checked** —
  head sha, run attempt, band multiplicity, conclusions. The gap was not a
  mistake in the recipe; it was a question the recipe did not contain.
  `ng ci-attempts` now answers it, in the recipe rather than in prose:
  `monitor/_merge_ref_base.sh` reads the runner's own
  `Merge <head> into <base>` checkout line — a RECORD OF WHAT WAS TESTED —
  and compares it against the PR's current base tip. A stale base **withholds
  the clearance at its own exit code 8**, whose action is its own (rebase or
  push, so a new run is computed against the current base; re-running CI at the
  same head cannot fix it, because `rerun-failed-jobs` reuses the merge ref from
  run creation).
  Every other available signal is a reconstruction and was rejected as such:
  reading `refs/pull/N/merge` **now** returns the merge recomputed since, and
  comparing run-creation time against the base tip's commit **date** is a
  heuristic that reports a stale run as fresh whenever a commit was authored
  before it was pushed — the unsafe direction. `gh api` for the log, never
  `gh run view --log`, whose 1.13.0 client returns zero lines at rc 0 (`#755`).
  **Three states, and `unread` is not folded into either of the others.** GitHub
  expires logs, so "could not read it" is ordinary and must not block; it is
  reported as `NOT CHECKED` beside the verdict — *"that is `not looked at`, NOT
  `looked at and current`"* — the same treatment absent attempt provenance
  already gets. A VERIFIED base is printed too, because a reader cannot
  otherwise tell a verified base from a check that never ran.
  The scan reads **several** successful runs, not the first: measured on
  `#823`'s own head, three of its successful runs check out
  `refs/remotes/origin/dev` directly and carry no merge line, while the round
  that ran the tests carries it. Reading only the first reports `unread` on the
  very head the check exists for — an *"I looked in the wrong place"* dressed as
  *"it cannot be known"*. Declared limit: if two rounds at one head tested
  different bases, the answer names the run it came from and does not detect the
  disagreement.
  `monitor/watcher/test-merge-ref-base.sh` (13 assertions) drives the library
  directly — including the **STALE** arm, which no live PR can be made to
  demonstrate on demand — with a negative-control mutant that makes a stale base
  read as current. `test-ci-head-attempts.sh` 22 → **25**, wiring the three
  states through the verb end-to-end.

- **`#812`'s credit, scoped.** The `skipped`-reads-as-`success` case is closed by
  machinery that already existed: `VERDICT_CONCLUSIONS` is an allowlist of
  `{success, failure}` and `classify_runs` returns `NO_VERDICT` for
  `skipped`/`cancelled`/`neutral`, and both are **untouched** by the `#812`
  change. `#812` closes a different hole — the expectations-only path, where no
  run data was supplied at all. The prior entry did not claim otherwise but did
  not say so either, and a changelog about verdicts that claim more than they
  measured should not leave that to the reader.

- **`ci-trigger-audit.py` announced a `success` verdict on the path where it was
  shown no runs (`#812`).** With `--observed` omitted the audit printed, two
  lines apart, `band multiplicity: NOT CHECKED — … that is 'not looked at', not
  'looked at and clean'` and `OK: every workflow that should have gated this PR
  has CONCLUDED and carries a success verdict`, at **rc 0** — and the `#748`
  qualifier that would have softened it was guarded by `elif observed is not
  None`, so the one path most in need of a qualifier received none. The `#762`
  shape one step further out: a positive claim quantified over something never
  measured, rendered as `OK` at exit 0, inside this repo's own instrument for
  detecting exactly that.
  The remedy is **structural, not editorial**, because a better sentence stays
  one edit away from being reachable again. The verdict sentence now lives in
  one function, `cleared_lines()`, guarded by `_require_measured()` which
  RAISES (`UnmeasuredClaim`) if it is ever reached without run data; the three
  terminal states are selected by one function, `clearance_report()`, on the
  question *what was this run in a position to answer* rather than *was
  anything wrong*; and the no-data case gets its own sentence and its own
  **exit code 7 (EXPECTATIONS ONLY)**. Both production callers pass
  `--observed` unconditionally, so 7 is unreachable there and their default
  arms make it fail closed.
  `test-ci-trigger-audit.sh` 59 → **66 assertions**, asserting the SENTENCE and
  not only the code — including the two absences (`^OK: `, ``carries a
  `success` verdict``) — plus a function-boundary probe that `cleared_lines(g,
  None)` raises, and **two negative-control mutants**: deleting the arm alone
  makes the precondition fire (rc 2, refused), deleting the arm *and* the
  precondition reproduces `#812` verbatim (rc 0 + the OK line over no data).

- **`test-remote-identity-health.sh` flaked on fixture startup because its port
  allocator predicted `bind()` from a `connect()` (`#769`), and threw away the
  evidence on every occurrence (`#794`).** The suite allocated fixture ports by
  probing with a TCP connect and handing back any port that refused it. A
  connect only detects a **listening** socket; it cannot see a port already held
  as the **ephemeral source port** of an outbound connection — and four of the
  five fixture windows sit inside the kernel's ephemeral range (32768–60999).
  Such a port answers the probe with "free" and then fails `bind()` with
  `[Errno 98] Address already in use`, `SO_REUSEADDR` or not. The allocator now
  probes by **binding** the port, which is the operation the fixture actually
  performs, and remembers ports found unusable so a retry tries a different one
  — without that, the probe is deterministic and re-hands the identical port
  (observed doing so three times on port 33054). Allocation also moved to
  immediately before each bind; it used to happen ~15 s earlier, at the top of
  the file. Case 0 is the regression test, with the holder modelled as a real
  ESTABLISHED outbound socket.
  The filed mechanism — "CPU contention against a bind-readiness ceiling" — is
  **refuted**: on the failing job the ceiling was 80 polls ≥ 16 s while the whole
  suite ran 15.67 s, and the captured post-mortems show the child exiting after
  **one** 0.2 s poll. No deadline was ever involved.
- **A fixture's readiness was a liveness proxy, in the suite whose purpose is
  refusing liveness proxies (`#769`).** "A TCP connect to my port succeeds" was
  read as "my fixture came up", so a stranger holding the port made the suite
  report the forger started and then measure the stranger — 82 passed, 8 failed,
  including `…named as IMPERSONATION` verbatim, i.e. accusing an unrelated
  process of impersonation. Readiness is now an **announcement**: `sshd -e`
  prints `Server listening on …`, and the two python fixtures print a `READY`
  line after `listen()`. Two listeners cannot hold one addr:port, so an
  announcement proves ownership.
- **A diagnostic may only name a path that outlives the process printing it
  (`#794`).** The fixture-start failure pointed at `$WORK/forge-<port>.log`, a
  file the suite's own `trap … EXIT` deletes before `run-tests.sh` records the
  failure and long before CI's `collect failure artifacts` step runs — confirmed
  by downloading all four artifacts of a real failing run, none of which contain
  it. Failure paths now print the log's **contents** inline, plus which exit the
  bind loop took and who holds the port. `#794` scoped this to one call site; a
  corpus scan over the pre-fix tree at `16728e7` finds **two**
  (`test-remote-identity-health.sh:531` and `test-mint-token.sh:300`), and
  `test-diagnostics-outlive-their-paths.sh` now pins the boundary as a manifest
  (currently empty) with its own positive and negative controls. The detector's
  span must span the whole diagnostic: an earlier draft stopped at `;`, which
  made it blind to `#794`'s own line — whose format string reads
  `(python3 is present; see %s)`. That case is now the positive control.

### Changed

- **An unstartable forging fixture is now `th_skip` with a named precondition
  rather than a FAIL (`#769`), gated on an allowlist with a default-deny arm.**
  Only a demonstrated host fault (seized port, bind ceiling, no free port) may
  downgrade; a broken `forge.py`, a bad pubkey or anything unclassified still
  FAILs. The three substrate fixtures deliberately keep the hard FAIL: the only
  mechanism for downgrading them is a file-level `exit 77`, whose reason
  `run-tests.sh` recovers from `head -n 3` of **stdout**, while these
  diagnostics are on stderr hundreds of lines in — it would render as a SKIP
  with an invisible cause. Verified by negative control: a real `#609`-class
  impersonation regression still reddens loudly (34 passed, **56 failed**, zero
  skips).

- **`live-skeptic-window` was matching a naming convention, not looking for a
  skeptic (`#771`).** The spawn-skeptic request's field that exists to stop
  duplicate review resolved via `grep -qxF "${target}-skeptic"` over
  `tmux list-windows`. Skeptic windows are not named that way: of 468
  `skeptic_role: true` spawn records on the reporting nexus, **198 (42%)**
  carry a name the pattern cannot match — `fig4sk`, `nexuscode-716sk`,
  `debench-skeptic3`, `skeptic-B7`, `audit-skeptic` for target `ncode-audit`.
  Each was invisible to the field from the moment it was spawned.
  - `#771` reported the symptom exactly right — `fig4sk` was `busy`,
    re-pinned, working the delta, while the request said `no`; four duplicate
    requests in twelve minutes — but hypothesised the detector keyed on
    **wrap-up bookkeeping**. It never did. Re-pinning correlates because
    iterative rounds are when an operator reaches for `…-skeptic2` or a short
    name; the field was equally wrong for those 198 windows on their *first*
    pass. The fix is correspondingly broader than the report.
  - A window is now live when the **spawn record**
    (`monitor/.state/windows/<w>.json`, `skeptic_role` + `skeptic_target`,
    written by `spawn-worker.sh --skeptic-role` itself) names this target,
    a tmux window of that name exists **now**, and the pane does not
    positively assert a dead agent. Records alone would be the opposite
    error — they are never pruned, so they answer "was there ever a skeptic".
    The legacy name match is kept as a **union member** so a pre-provenance
    window still counts.
  - Liveness gates on new `bk_pane_asserts_dead`, true for `absent` and
    nothing else — the **dual** of `bk_pane_kill_authorized`, not its
    negation. Both are default-deny; they differ in which act is dangerous,
    so reusing the kill predicate here would invert it: `idle` is
    kill-authorised, and an `idle` skeptic is the most re-pinnable state
    there is. Every indeterminate reading (`empty` especially) and every
    state a future `pane-state.sh` adds resolves to **alive**.
  - **Which way it errs, stated rather than left to fall out.** The field
    never suppresses the request, so a wrong `yes` costs one look at a named
    window while a wrong `no` costs a duplicate reviewer rebuilding an
    enumeration and posting into an issue the operator is reading. It errs
    toward `yes`. "Could not look" (no tmux, no window list, no `jq`) is a
    third value, `unknown`, not laundered into `no`; every verdict quotes the
    evidence it rests on.
  - Applying the same rule to the fix turned up one more instance: the
    single-batch `jq` over the record store aborts on the first **malformed**
    record, exiting non-zero having emitted only the files it reached — an
    invisible truncation feeding a confident `no`. The rc is now read; partial
    results are still used, but the lookup is marked blind, and a blind lookup
    cannot produce `no`.

- **`test-remote-identity-health.sh`'s three fixture daemons now scale their
  bind ceilings, instead of asserting an unloaded-host timing (`#558` class).**
  The suite referenced `th_deadline` **zero** times: `start_sshd` (12 s),
  `start_banner_only` (8 s) and `start_forger` (8 s) each polled a flat,
  unscaled ceiling. At `--jobs 4` on a 2-vCPU runner that reddened case 12 —
  `the forging fixture could not start — case 12 did NOT run` — in **one of six**
  matrix cells, the one whose name (`NEXUS_ROOT exported`) invites a
  configuration diagnosis it does not deserve.

  This is verbatim the failure `th_deadline`'s own docstring documents:
  *"`test-jupyter-service.sh` … green 93/93 standalone, failing EVERY
  full-suite run at `--jobs 4`, because its 20 s deadlines were sized on an
  idle host. Nothing was wrong with the code under test."*

  Evidence it is the deadline and not the environment variable: the suite
  passes **6/6 locally with `NEXUS_ROOT` exported AND with it unset**, and it
  was green in that same cell one commit earlier. A polled ceiling costs zero
  wall time on a green run, so scaling changes only how long a genuinely broken
  fixture takes to be declared broken — at scale 1 the poll counts are
  byte-identical to the old flat values.

  Fixed by scaling rather than by raising the flat number, and **not** by
  re-running the band: a retried green is not a first-pass green, and
  `ci-signal` reports it as `REPLACED-VERDICT` (exit 6) precisely so it cannot
  be laundered.

### Added

- **`CLAUDE.md` gotcha: a value sampled across refs is a timeline only if each
  ref is an ancestor of the next (`#804`).** `git show <ref>:<path>` answers
  "what did this tree contain", never "what happened in what order" — but a
  monotone count series *reads* as a narrative, and the narrative is usually the
  thing you were trying to establish. It has already published a wrong
  mechanism: a `3 → 0 → 0 → 1` series across four unrelated branch tips became
  "`#791` fixed it and `#781`'s merge resurrected it", when the function being
  counted did not exist on `#791`'s branch at all (retracted on `#790`).
  The entry carries the two-line check in a delimited block, executed by
  `test-claude-md-ancestor-timeline.sh` against a fixture repo whose true
  history is known by construction — so the expectation never comes from the
  thing under test. The suite reproduces the trap rather than only guarding
  against it: it asserts the misleading series is exactly `3 0 0 1` **and that
  every `git show` in it exits 0**, because the defect is not that the wrong
  reading fails but that it succeeds while lying. A linear chain is the positive
  control, without which an `--is-ancestor` that always said no would pass.
  The zsh half is pinned too, since it fires on this exact call shape:
  `git show "$ref:results/count.txt"` silently becomes `mainesults/count.txt`
  (`:r`), so the documented form is always braced. That assertion **skips
  loudly** where zsh is absent rather than passing silently.

- **`monitor/guards-for-diff.sh` — which guards READ the files you changed
  (`#803`), asked of the guards themselves.** A PR's green covers the suites its
  diff **touches**, not the suites its change **affects**; three occurrences in
  one night, each a guard whose scanned population the change had just entered,
  keyed on a source construct rather than on a directory. "Run the full suite"
  is the workaround (~570 s over 270 files), so in practice workers run what
  they *believe* is relevant — and believing correctly is what failed three
  times.
  There is **no registry of guards** in the tool. A guard is discovered iff it
  implements the `--population` protocol (`monitor/_guard_population.sh`), and
  the discovery predicate is the implementation itself — the literal call
  `gp_handle "$@"` — not a name, a directory, or a comment that can drift from
  it. Deliberately the CALL and not the flag string: a rule whose false
  positive is *execute an arbitrary test suite* is not a discovery rule.
  **Population means the set of files whose BYTES a guard reads**, not the set
  where the construct occurs. A file scanned and found clean is exactly the file
  an edit can dirty. That definition is what makes selection sound in the
  direction that matters (a guard that does not read your file cannot be
  affected by editing it); the converse is not claimed, so the index
  over-selects on purpose. Six guards enrolled, each declaring by calling its
  **own** enumerator — never a copy, because a copy drifts and the index then
  reports with total confidence that a guard does not read a file it does read.
  Everything is fail-CLOSED: an empty population, an enumerator that errors, a
  path that no longer exists, or a guard the index could not ask are all
  REFUSALS, because downstream each is indistinguishable from "does not read
  your diff". An empty **selection** is a sentence with the full considered
  list and its own exit code (3), never silence.
  The coverage boundary is pinned as DATA in
  `monitor/watcher/guard-populations.manifest` and enforced by
  `monitor/watcher/test-guards-for-diff.sh` (40 assertions), on the axis the
  mechanism varies on — **how a guard declares what it reads**. The index
  prints its own residual on every run (*291 of 297 tracked suites declare
  nothing and are invisible to this index; it is not a substitute for the full
  suite*), so the number is measured rather than implied, and it is a ratchet
  that should only fall. It also states the one thing no per-branch index can
  see: populations are computed against **your** tree, so a guard whose
  population DEFINITION changed on another branch selects differently after
  merge — `#803`'s first occurrence (`#781` × `#791`) exactly.
  Available as `ng guards-for-diff [--run]`.

- **`ng-usage.jsonl` rows name their producing suite (`#720`).** `win` is empty
  on every row written on a CI runner (no tmux) and `ts` has one-second
  resolution while the band runs at `--jobs 4`, so the CI occurrence at
  `d1cc62b` — 23 rows leaked into the inherited root — was narrowable to four
  concurrent `ng`-verb suites and no further. `#720`'s own comment named two
  remedies and called this the better one: `watcher/run-tests.sh` now sets
  `NEXUS_TEST_SUITE=<parent>/<basename>` per child and `_usage_tap` writes it as
  a new `src` field, so the row is self-attributing with no second run, no
  bisect and no runner minutes — and it survives any future `--jobs` value,
  which serialising the band would not. A separate field, never folded into
  `win`, which `ng usage` groups by.
  **`#720` is not closed by this.** Its closing condition is a CI occurrence
  classified to a producing suite; this is the instrument that makes the next
  one classifiable, which is a different claim. The prior negative (31 probed,
  17 hermetic, 14 TIMEOUT, 0 leaks) is untouched and was **not** re-derived —
  the selector that produced "31" is a description of a result, not a
  reproducible predicate, and re-collecting under a fresh grep would be
  `#721` rewrite 1's error a third time.

- **`monitor.integration_branch` — one property, one claimant, enforced by
  construction (`#763`).** "The branch merged fixes land on" is repo-wide,
  but it was recorded under `monitor.clone_drift.branch`, a name scoped to
  one of its two consumers, and each consumer looked it up on its own.
  `#754` declined to fix the name precisely because a second key would be
  *worse* than the bad one: two records of one property drift apart, and the
  deployment gate and the drift detector would then disagree about the same
  clone. So the fix is a shared resolver, not a rename.
  - `monitor/_integration_branch.sh` (new) is the single chain:
    `$MONITOR_INTEGRATION_BRANCH` → `$MONITOR_CLONE_DRIFT_BRANCH`
    (deprecated) → `monitor.integration_branch` → `monitor.clone_drift.branch`
    (deprecated, honoured with a one-line note) → `dev`. Both consumers —
    `monitor/watcher/_clone_drift.sh` and `cc-auto-update-apply.sh`'s
    `_gate_integration_branch` — now call it and hold no private lookup.
    `_clone_drift_tick`'s own `${MONITOR_CLONE_DRIFT_BRANCH:-dev}` was a
    second claimant in its own right: it answered `dev` for every caller
    that had not sourced `_config.sh`.
  - **The migration is the hazard, not the rename.** `config/nexus.yml` is
    per-operator and not tracked here, so a bare rename lands on every clone
    as a silent default-fallback — the new key absent, the default applied,
    an operator who deliberately set `release` silently getting `dev`,
    nothing erroring, on the surface `#754` had just finished making
    trustworthy. Hence read-both / prefer-new / note-on-old.
  - **The trap lives inside the remedy.** `config/load.sh <key> <default>`
    prints `dev` both for "absent" and for "set to dev", so a resolver
    written that way never reaches the deprecated key and reproduces the
    reported bug inside its own fix. The resolver therefore calls the loader
    with **no default** and branches on the exit code — rc 2 (absent) is the
    only code that licenses falling through; rc 1/3 ("could not look") get a
    distinct `default-unreadable-config` source and a loud note, because a
    missing config file must not read like a deliberate `dev`.
  - Both keys present with different values is reported as a `CONFLICT`
    rather than silently resolved. `monitor/watcher/test-config-integration-branch.sh`
    (new, 44 assertions) pins the old-key-only/non-default case together with
    a **negative control** that runs the naive rename against the same
    fixture and asserts it answers `dev`; `test-cc-auto-update.sh` gains the
    gate-level twin.
  - The resolver is a core (`_nexus_resolve_integration_branch`, sets
    `$NEXUS_INTEGRATION_BRANCH_VALUE`/`_SOURCE` in the caller's shell) plus
    two wrappers: the branch on stdout, or `<branch>\t<source>` for the
    `$( )` caller. Smoke-testing `_config.sh` under `set -u` caught the first
    shape asserting a contract it did not keep — `$( )` is a subshell, so the
    provenance assignment died there and a reader got "unbound variable".
  - **The deprecated key is read until 2026-11-07**, a date carried in the
    operator-facing note itself (not only in this changelog) and asserted
    identical across the resolver, `monitor/README.md` and
    `config/nexus.example.yml`.

- **A merge-conflict marker in a tracked file now reddens CI, and it is
  checked tree-wide rather than per-suite (`#774`).** One `|||||||` line in
  `CHANGELOG.md` reached `dev` and survived **seven** consecutive merges.
  Re-derived from history here (marker count in the merge, then in each
  parent): `#760` 0/0/0 · `#759` 1/0/**1** · `#758` 1/1/0 · `#761` 0/1/0 ·
  `#766` 0/0/0 · `#756` 1/0/**2** · `#772` 1/1/0. Non-monotonic: introduced on
  the `#759` head, silently removed by an unrelated rebase resolution at
  `#761`, silently reintroduced on the `#756` head. No step in that sequence
  was aware of it, because nothing looked.
  - `monitor/test-conflict-marker-lint.sh` (new) scans every `git ls-files`
    path for all four canonical markers. Replayed against history it reddens
    at exactly the four merges that carried one and stays green at the three
    that did not.
  - **The diff3 marker is the one that matters, and a guard checking only
    `<<<<<<<`/`>>>>>>>` reproduces the bug.** Every marker in this repo's
    history was `|||||||` — it appears only under `merge.conflictStyle =
    diff3` and, rendered in a Markdown changelog between two bullet blocks, it
    does not *look* like damage.
  - **No filename allowlist and no exemption mechanism at all.** The lint scans
    itself like any other file; assertions fail if either `CHANGELOG.md` or the
    lint drops out of the scanned set. What makes that safe is that **markers
    are matched only at LINE START — never begin a line with one; indent an
    illustrative marker by one space.** That rule is now pinned by four
    assertions (column 0 matches; the same marker indented, mid-line, or in
    backticks does not), because the justification first recorded here — "the
    lint carries no literal marker anywhere" — was **false**: the trailing
    comments on its own pattern constructors are literal seven-runs, harmless
    only because they sit mid-line. The distinction matters because this gate
    has no escape hatch and runs on every PR, and a fenced example of a
    conflict is a natural thing to write when documenting this very feature.
  - `.github/workflows/conflict-markers.yml` (new) runs it with **no `paths:`
    and no `branches:` filter**. `CHANGELOG.md` matches no existing workflow's
    filter, so `ci-trigger-audit.py` reported `gating workflows for this PR:
    NONE` — exit 0 — for a CHANGELOG-only change; it now names this workflow.
    Adding `CHANGELOG.md` to `tests.yml` would have been a filename allowlist
    standing in for a whole-tree property. The two triggers are not redundant:
    `pull_request` checks the merge preview, `push` is the only one that can
    see a marker introduced **by the merge resolution itself**, which `#761`
    and `#756` show is a real source and not a hypothetical one.

- **A boot wedged on the Bypass Permissions modal now names itself instead of
  reporting `empty` (`#768`).** The binary migrates
  `.claude.json`'s `bypassPermissionsModeAccepted` into `settings.json` as
  `skipDangerousModePermissionPrompt: true` and **deletes the original**
  (measured on 2.1.224), so after any boot only `settings.json` suppresses the
  warning — and anything rewriting that file between boots without
  re-supplying the key wedges the next boot on the modal.
  - The modal reached **no** overlay arm in `monitor/pane-state.sh`: it has a
    `❯ N.` menu but not `Do you want to proceed?`, so it fell through to the
    input-row logic. With claude alive that yields `empty` — *"don't know
    yet"* — so a deterministic config fault presented as a **slow boot**. It
    cost a probe run of three cells reported as "VI mode is unreachable". That
    `empty` path is what this arm addresses, and only it: a pane whose pid
    yields no live claude reports `absent` (the one **kill-authorising** state)
    from a liveness gate ~260 lines upstream that the overlay check never
    reaches. Moot in production — a wedged modal means claude is alive — but
    the `absent` side is `#780`'s territory, not this arm's.
  - `_has_bypass_permissions_modal` adds the fourth arm, and `state=blocked`
    now always carries `overlay=<rate-limit|permission|bypass-permissions|askuq>`.
    `blocked` was already correct for all four (it is in `_BK_ACTIVE_STATES`,
    so never kill-authorised, and no `_unstick.sh` arm fires on this modal —
    every arm there needs two co-occurring literals it does not carry, so
    nothing auto-answers a security prompt). The **kind** is what turns
    "something is blocked" into a diagnosis.
  - A **live-vs-quoted guard** is load-bearing rather than defensive: the
    modal's text is quoted in the issue, in `pane-state.sh`'s own comment and in
    `synthesize.sh`, so any agent reading them has every shape literal on
    screen. It is **two** tests, and the structural one carries the weight: a
    live modal REPLACES the REPL, so no `❯<NBSP>` input row may appear below the
    footer. A bottom-slice margin alone was not enough — the `#776` skeptic
    **constructed** the pane that defeats it (an idle agent quoting the modal
    with two chrome rows below), which is now a committed boundary fixture.
    Their proposed remedy, tightening the slice to `tail -n 1`, was declined
    with reason: it keeps a margin as the discriminator and trades a
    safe-direction false positive for an **unsafe** false negative — trailing
    chrome on a real wedged pane would drop the case back to `empty`, and
    neither of us has a capture of one. Each test is proven load-bearing by a
    mutation against the pane only *it* rejects.
  - **A name nobody prints is not a diagnosis**, so the cc-harness
    `wait_for`'s expiry now
    emits the observed pane-state line — and, for this overlay, the re-seed
    remedy. `monitor/watcher/test-cc-harness-waitfor-diagnostic.sh` (new)
    covers it hermetically (no binary, no node, no tmux): it is a
    FAILURE-path emit, which a passing gate run never exercises. Its controls
    are the load-bearing part — a plain `state=empty` must still be reported
    but must NOT be attributed to the modal, a `permission` overlay is
    reported as itself, and a satisfied wait stays silent.
  - Recorded where the next person meets it: cc-update collision surfaces
    `2d` (the migration, with the measured before/after) and `2a` (the modal
    literals are now a detection surface).

- **A `nexus-remote-ssh` port change now reaches the operator durably, and
  the alert itself fails loud (`#757`).** `select_and_record_port`'s header
  promised an alert that is *"LOUD and DURABLY"*; what implemented it was a
  single `sandbox-notify`, `2>/dev/null`-muted and `|| true`-swallowed. The
  port-selection logic was and stays sound — sticky preference, fail-closed
  identity probe, refusal to move on an INDETERMINATE verdict. The **alert**
  was the defect, and it is this repo's dominant class (silence read as
  delivery) arriving one layer up.
  - A bell is ephemeral, and the event it exists for is a reboot-time
    bring-up. Worse, and **measured** rather than reasoned: that exact message
    matches no arm in `monitor/notifywrap/sandbox-notify` and falls to the
    default `task` class — the catch-all every worker `ready`/`done` ping also
    lands in — so its 300 s cross-window cooldown BATCHES it. Fire any other
    task-class bell, then the port alert 1 s later, and the decision log reads
    `"verdict":"suppress-cooldown"` with zero bells emitted.
  - `monitor/remote-port-change-notify.sh` (new) fires **only on an actual
    recorded change** (a sticky recorded port never re-fires, so a restart loop
    cannot spam) and fans out over surfaces that outlive the session: a bot
    comment on the operator's endpoint tracking issue, a push
    (`monitor/notify.sh --priority emergency --require-delivery`), and a local
    copy that is deliberately **not** counted as delivery.
  - The issue target resolves from new `monitor.remote.endpoint_issue` /
    `endpoint_issue_repo` keys with **no default** — nexus-code is cloned by
    every operator, and a literal number would post one operator's endpoint
    into somebody else's thread. **Unset is a FAILED surface, never a silent
    skip.**
  - The comment carries *the exact text to forward to the client agent*: new
    `host:port`, the fingerprint to re-pin (unchanged — the host key does not
    move), and, when `_remote_from_audit` says so, **"a re-enroll is also
    owed"** with the remedy, so a port change and a `from_cidr` re-pin are one
    client touch rather than two. That paste (`_remote_client_repin_notice`) is
    single-sourced with `_remote_onboarding_notice` through the new
    `_remote_endpoint_params`, so the out-of-band text cannot drift from what
    the client is told once it reconnects.
  - Fail-loud without blocking: zero durable deliveries ⇒ exit 3 plus a
    `port-change-notice.UNDELIVERED` marker that `remote-up.sh --status`
    surfaces on **every** run until resolved. The bring-up still completes —
    the port has already moved and been recorded by then, so aborting would
    leave a stale client *and* a dead endpoint.
  - The transient bell is kept but prefixed `CRITICAL:`, which measurably
    moves it out of the `task` catch-all into the `critical` class — it now
    rings where the shipped text read `suppress-cooldown` under identical
    conditions. It stays defence in depth, never the durable surface, and its
    failure is reported rather than swallowed.
  - **The marker's OWN failures are reported too.** A skeptic pass found the
    persistence mechanism was itself `|| true`-swallowed: on an unwritable
    `principals_dir` the emitter announced "Marker written" with no marker on
    disk, and a successful delivery whose `rm -f` failed left a STALE marker
    that `--status` would then cry wolf over forever, silently. Both paths now
    pre-check writability — so a shell redirection diagnostic cannot bleed out
    unattributed (`#723`) — and VERIFY rather than assume. Neither changes the
    delivery verdict.
  - A refusing `--dry-run` no longer arms the persistent marker: a rehearsal
    was never going to deliver, so there is no delivery failure to make
    durable, and marking would make `--status` cry wolf over a notice that
    does not exist — the inverse of the failure the marker exists to prevent.
    The gate still runs in dry-run (a rehearsal that skips the gate the real
    run must pass is not a rehearsal), and the refusal is still loud and rc 3.
  - `monitor/watcher/test-remote-port-change-notify.sh` (new): 124 assertions
    enumerating the axis the mechanism varies on (which durable surface
    accepted), shown non-vacuous by 13 mutants — the reverted swallow, an
    always-0 verdict, a silent unconfigured skip, a removed secret guard, a
    dropped re-enroll clause, an uncleared marker, a blocking alert, a silent
    `--status`, a reverted `CRITICAL:` prefix, an unchecked marker write, and
    a silent stale-marker clear, a marker-arming rehearsal, and a gate-skipping
    rehearsal — each reddening distinct assertions with the count unchanged
    at 124.

- **A red in the SLOW band can no longer be silent about which assertion
  failed (`#752`), and the respawn fixture can no longer spawn the
  operator's real Claude Code binary (`#746`).**

  `#752` was filed as a suspected flake: at head `d4df844f`
  (run `31153179861`) the blocking SLOW band went red on attempt 1 and
  green on attempt 2 at the same sha, with `test-respawn-loop-integration.sh`
  reporting `rc=1` and **no** failing assertion. Reading both attempts'
  artifacts refutes the premise. That test failed on **both** attempts,
  identically; it was a tolerated entry in `monitor/slow-band-known-red.tsv`
  at that sha, so the job went green anyway. The only test that flipped is
  `test-jupyter-service.sh`, already fixed by `#749`. There was no flake here
  to diagnose — the red was deterministic and knowingly excused.

  What was real is the legibility half. `run-tests.sh` built its failure
  detail by tailing `.err` alone — a **proxy** for "show what the test said".
  That suite's `.err` was 0 bytes and its `.out` was 10,563 bytes ending
  `FAIL: guard did not trip within deadline`, so the runner had the diagnosis
  on disk and printed none of it. The fix is in the **runner**, not the tests:
  the affected set is not statically decidable, because sourcing
  `_test_helpers.sh` is no guarantee — that suite *does* source it and routes
  every `assert_*` to stderr correctly, but hand-rolls its terminal verdict.
  A corpus scan misses the very file that motivated the change — and does so
  under *every* operationalization, since that suite carries `FAIL … >&2` at
  its fixture-drift guard, so any static "does it route FAIL to stderr" scan
  classifies it compliant. (One such scan scores 63 of 271; the predicate is
  spelled out verbatim at `_rt_failure_tail`, because the phrase alone admits
  readings scoring 23-207.) `run-tests.sh` now falls
  back to the stdout tail when stderr is empty, labels which stream it read,
  and says so explicitly when a test emitted nothing at all.

  `#746`: the fixture installs a stub `claude` and puts its dir first on
  `PATH`, but that does not make the stub win — `monitor/locals-env.sh`
  re-fronts `$NEXUS_LOCALS/bin` ahead of it, reached by every non-interactive
  bash via `BASH_ENV`. Running the band the documented way therefore started a
  **real, billed Claude Code session inside the fixture**; CI escaped only
  because it invokes the band under `env -u NEXUS_ROOT -u NEXUS_LOCALS`. New
  shared helper `th_require_stub_claude` asserts the **resolution** rather than
  PATH order (an exported `CLAUDE_BIN` short-circuits `_claude-bin.sh` before
  `PATH` is consulted at all) and refuses before anything spawns. The fixture's
  crash-log guard also stopped asserting *fixture copy-list drift* as the cause
  — a real failure mode this file has had three times, and the wrong one on
  `#746`, which sent the reporter to audit the one place the problem was not.
  It now states what was observed and ranks the candidates.

  Also measured while here: this test hardcoded a bare `+ 60` deadline and
  never called `th_deadline`, so `#749`'s band-wide `NEXUS_TEST_DEADLINE_SCALE=2`
  had **no effect on it** — `#752`'s hypothesis that `#749` "may well cover
  this too" cannot hold. It now scales.

- **A workflow can no longer invoke `run-tests.sh` with an inert deadline
  scale (`#751`, generalising `#749`).** `th_deadline()` scales polled
  deadlines by CPU oversubscription, `ceil(NEXUS_TEST_JOBS / nproc)`. A band
  passing no `--jobs` gets `jobs=1`, so on a 2-vCPU `ubuntu-latest` the scale
  is `ceil(1/2) = 1` and every deadline is its bare literal — while the
  deadlines carry comments saying they are scaled. `#749` made the effective
  scale *visible* in `run-tests.sh`'s header; that is legibility, and it
  requires someone to read the log of a run that already happened.

  New `lint-workflows.py` rule family **TD**. `TD001` requires any step
  invoking `monitor/watcher/run-tests.sh` to either set
  `NEXUS_TEST_DEADLINE_SCALE` explicitly or pass `--jobs N` with **N greater
  than** the runner's vCPU count. The `>` is load-bearing: `ceil` is not
  strictly increasing here, so `--jobs 2` on a 2-vCPU runner is `ceil(2/2) = 1`,
  identical to passing nothing — a rule demanding merely "some `--jobs`" would
  bless the inert case. This widens the linter's remit from MC + SR, a scope
  decision `#751` hands over deliberately.

  Verified against its own motivating case: run against the workflow file as
  it stood *before* `#749`'s fix, `TD001` flags the exact step `#749` repaired.
  A rule that would not have caught the bug it generalises is not a fix.

  Re-deriving the call sites found **four** exposed, not the two `#751`
  enumerated: `cc-harness.yml`'s real-binary scenarios (sequential, so no
  `--jobs`, and its deadlines poll a real Claude Code pane — the slowest thing
  this repo waits on), two steps in `tests-slow-integration.yml`'s
  `slow-integration` job, and `tests.yml`'s `jobs: 2` matrix cell. All four now
  set the scale explicitly; setting it only lengthens deadlines, so the change
  cannot introduce a new failure.

  Coverage boundary, stated on the rule: TD001 judges the **invocation**, not
  whether the tests behind it honour the scale. A test that hardcodes a literal
  deadline instead of calling `th_deadline` is invisible to this rule *and* to
  `#749`'s header — both report the scale, neither reports who consults it.
  `test-respawn-loop-integration.sh` was exactly that case (`#752`).

- **The cc-harness now boots the keyboard mode production actually runs
  (`#724`).** `cch_setup` seeded no `editorMode`, so every real-binary
  scenario — and the whole pre-update gate — booted the DEFAULT mode while
  every nexus agent inherits `editorMode: "vim"` from user scope. The gate
  was validating a configuration nobody is in, same class as the `tui` fix
  in `#568`. It is not cosmetic: vim mode paints `-- INSERT --` into the
  status row, and `pane-state.sh`'s `_detect_vim_insert` reads exactly that
  row to decide `user-typing` vs `idle`, so the production keyboard mode is
  an INPUT to the classification the harness exists to gate.

  Measured against 2.1.224 before seeding anything, because seeding it by a
  route production does not use would reproduce the defect one level down:
  the key is live in BOTH `$CLAUDE_CONFIG_DIR/settings.json` and
  `.claude.json`, and either alone suffices — `-- INSERT --` renders from a
  settings.json-only seed, from a .claude.json-only seed, and from neither
  when neither is present. The harness seeds it the way the operator
  declares it.

  `test-realmodel-vimode.sh` is committed rather than left as the throwaway
  scratchpad probe of the 2.1.223 evaluation, so no future candidate
  evaluation restarts blind, and it is wired into `gate.sh`'s HARDCODED
  scenario list — a scenario that exists but is not named there is not
  gated, which would have been `#724` one level down. The **control boot is
  the non-vacuity assertion**, because the obvious version of this test is
  vacuous: an unseeded vim probe asserts a marker against a binary never put
  into vim mode. Seeded worker => marker PRESENT, unseeded control => marker
  ABSENT; neither cell alone is evidence.

- **A shell-option scope guard (`#721`).** `test-ambient-shell-option-scope.sh`
  holds the two invariants that keep `#721`'s masking class dormant: no test
  file may both set an option ambiently and source a library that scopes it
  (P1), and no SOURCED library may restore an option with an unconditional
  `shopt -u` (P2). P2's population is DERIVED from the tree rather than
  listed — a leak crosses a function return, not a process boundary, so a
  script nothing sources cannot leak to anybody, and the day something
  sources it the file enters the gated set on its own.

  P1's envelope is narrower than that sentence and the file says so where a
  reader hits it: *glob-family options, line-anchored `shopt -s`, DIRECTLY
  sourced libraries.* Transitive sourcing, non-glob options and inline
  conditional setters are out of reach — measured, not live on this tree, and
  tracked as a follow-up. A guard that overstates its envelope is worse than a
  narrow one.

### Fixed

- **Three checks that answered a different question than the one asked, and
  reported success (`#762`, `#773`, `#765`).** One defect class in three
  costumes: *did the concluded runs pass?* substituted for *did everything
  conclude?*; *is Actions broken?* for *is this PR conflicted?*; *did the
  triggered workflows pass?* for *was this change actually tested?* Each
  substitution renders as a green.
  - **`#762` — a green quantified over an empty set.** `ci-trigger-audit.py`'s
    `OK:` line and `ci-head-attempts.sh`'s `VERDICT:` lines both asserted over
    the CONCLUDED subset, so a head whose bands were all `in_progress` made
    the claim vacuously true and printed it as `OK` … `cleared`, at exit 0.
    Observed live on PR `#758`'s own head. The per-row output already said
    `.... still in_progress`, which is the tell that the bug was in the
    AGGREGATION — so the fix changes what the claim is quantified over
    (`gating`, not `gating minus pending`) rather than rewording the summary.
    New exit **3**, NOT CONCLUDED, with distinct sentences for "none
    concluded" (no evidence at all) and "some concluded" (partial and
    provisional) under one code, because the belief differs and the action
    does not.
  - The two consumers want opposite things from that state, which is why one
    number could not serve both. `ci-signal.yml` is a PEER check racing its
    siblings — it finishes in about a minute, the bands take tens of minutes —
    so it maps 3 to success and says so in a `::notice::`; reddening it would
    have muted the guard on essentially every PR. `ng ci-attempts` is read on
    the MERGE path and maps the same 3 to a refusal to clear. Both boundaries
    are stated in code at the point the reader forms the belief.
  - **`#773` — a conflicted PR gets ZERO check-runs by construction.** A
    fourth cause of the empty observed set that `#758`'s three-way
    decomposition did not name: with `mergeable_state: dirty` the merge ref
    `refs/pull/N/merge` is uncomputable, and `push:` is scoped `[main, dev]`,
    so neither trigger can fire. It landed in the outage arm and pointed the
    reader at GitHub — which on PR `#744` produced the diagnosis "Actions
    stopped creating runs repo-wide" while PR `#767` had 13 runs at the same
    moment. Now its own arm and its own exit **7**, with a remedy naming the
    rebase. The issue supposed `mergeable_state` was already fetched here; it
    was not, appearing only in a comment, so this costs one API call — spent
    lazily, only on the paths where the answer changes the advice, and cached.
  - The arm's boundary is drawn in code, not only in prose: `dirty` is
    CLAIMED; `clean|behind|blocked|unstable|draft|has_hooks` are NOT (none
    stops the merge ref computing, and `behind` in particular is not a
    conflict); and `unknown` is neither — GitHub computes mergeability in a
    background job, so it is retried and then REPORTED as unread rather than
    silently read as "not conflicted".
  - **`#765` — a path filter that hid the runner it invokes.**
    `cc-harness.yml`'s `paths:` omitted `monitor/watcher/run-tests.sh` and
    `monitor/watcher/_test_helpers.sh`, so a PR to the real-binary runner got
    zero real-binary evidence behind a full, correct-looking enumeration.
    `#568` D6 had already fixed this once by hand under a comment stating the
    principle exactly — and left the runner out, because nothing recomputed
    the closure.
  - So the filter is now **derived, not patched**: new rule family **PF** in
    `monitor/lint-workflows.py` computes a workflow's transitive
    execute/source closure from its own `run:` steps and fails when the
    `paths:` filter does not cover it. It found **eight** omissions, not two —
    including `monitor/_submit_evidence.sh`, three hops out
    (`pane-state.sh` → `_idle_probe.sh` → `../_submit_evidence.sh`) behind an
    inline `$(dirname "${BASH_SOURCE[0]}")`, which is why no reader ever wrote
    it down.
  - PF is a **lower bound** and says so wherever it reports: a path built from
    a runtime variable cannot be resolved, so unresolved edges are counted and
    printed, and a clean PF result means "no hole on the edges it could
    follow", never "the filter is complete". It deliberately does NOT flag
    superfluous entries — the lower bound makes "matches nothing I derived"
    evidence of nothing.
  - **`tests.yml` does NOT have the same hole**, checked rather than assumed:
    PF reports it CHECKED and clean, because its filter globs coarsely
    (`monitor/**`, `config/**`, `.github/workflows/**`, `CLAUDE.md`) where
    `cc-harness.yml` enumerates leaf files. Enumeration is kept for
    `cc-harness.yml` regardless — it boots the real binary twice, and
    `monitor/**` would run it on every unrelated monitor change — which is
    safe now only because PF checks it.
  - **And a fourth, found by `#762`'s own PR going red: `ci-signal.yml`'s
    exit-code dispatch was DEAD CODE for every non-zero rc.** GitHub runs
    `run:` bodies under `bash -e {0}`; the audit step opened with `set -uo
    pipefail`, which does not clear `-e`, and ran the audit as `python3 … |
    tee`. Under errexit+pipefail a non-zero audit aborted the step AT THE
    PIPELINE — before `rc=${PIPESTATUS[0]}`, so the whole `case "$rc"` never
    ran and not one `::error::ci-signal: …` explanation was ever emitted. The
    red was correct; the sentence saying WHY was silently dropped. This is
    `#739` recurring in a second workflow, and the same defect class again: an
    absence that looks like nothing is missing, inside the guard written
    against it. Fixed with an explicit `set +e -uo pipefail`, guarded by a new
    `monitor/test-ci-signal-step-contract.sh` (8 assertions) that EXTRACTS the
    real step body and EXECUTES it under `bash -e` — the sibling of
    `test-slow-band-step-contract.sh`, same method, other file — with a mutant
    restoring `set -uo pipefail` to prove `+e` is what makes the dispatch
    reachable.
  - **And the skeptic pass on this change caught the same defect in its own
    remedy.** `ci-signal.yml`'s new comment justified mapping exit 3 to success
    with *"the pending bands carry their own required check-runs and GitHub's
    own gate independently blocks the button on them."* **Both halves are false
    here** — `branches/{dev,main}` report `protected: false` with
    `required_status_checks.contexts: []`, all three ruleset endpoints return
    `[]`, and a live PR with six `failure` check-runs reports
    `mergeable_state: unstable` rather than `blocked`. The sentence was
    inherited verbatim from issue `#762`'s own text, and this change's own
    report contained the refuting fact. Citing a guard that does not exist, in
    a change whose thesis is that stated-but-unchecked properties are the
    dominant defect, WAS that defect. The mapping stands on two grounds that
    are actually true — it is structurally unreachable when a band is absent
    (that is exit 4, and 4 is red), and pending is the normal state for a peer
    check that finishes minutes before its siblings — and the consequence is
    recorded plainly: `ng ci-attempts` returning 3 is not a second line of
    defence, it is the only one.
  - Also from that pass: the rc 3 arm now **returns** instead of rewriting `rc`
    and falling into the `case`, which had *also* printed the rc-0 arm's
    "every gating workflow … carries a success verdict" — the vacuous
    quantifier this entry is about, printed directly beneath the honest notice
    that contradicts it. Pinned by a new assertion, verified non-vacuous by
    mutation. PF now prints its resolved/unresolved edge counts on the **clean**
    path too, not only beside a finding, since green is where a bounded claim
    gets over-read (`cc-harness.yml`: 24 resolved, 22 unresolved). And the
    `#568` D6 comment is corrected: `_harness.sh`/`stub-claude.sh` are the
    substrate of the five **integration** scenarios, not of this workflow's
    realmodel ones — a true fact attached to the wrong workflow's filter. The
    entries are kept (over-inclusion hides nothing, and `monitor/**` already
    gates them elsewhere) but no longer document a false dependency.
  - Tests, each demonstrated red on the pre-fix commit rather than asserted:
    `test-ci-trigger-audit.sh` 47 → 53 assertions (case 10k, which had PINNED
    the defect by asserting rc 0 for an all-`in_progress` head, now asserts
    rc 3; plus a partial case, a control, a distinctness case and a mutant
    that restores the vacuous green); `test-ci-head-attempts.sh` 14 → 20
    (all-pending, partial, control, `dirty`, a clean-PR control proving the
    arm discriminates rather than relabels, and `unknown`);
    `test-lint-workflows.sh` 18 → 23 (four planted PF repos in `--selftest`
    plus two mutants of the real `cc-harness.yml` — one restoring `#765`
    verbatim, one stripping the three-hop edge so a resolver that degraded to
    one hop cannot pass).

- **Three sourced libraries no longer hand their caller a glob option OFF
  however it had it (`#721`).** `_trash.sh:158` and `watcher/_requests.sh`
  x2 converted to the `shopt -p` / `eval` save-restore form already in
  `watcher/main.sh` and adopted by `#726` at `_idle_probe.sh`. These three
  are the only ones of `#721`'s eight listed sites that are structurally
  CAPABLE of leaking; the other four (`install-claude-local.sh`,
  `upload-asset.sh`, `ng` x2) are sourced by nothing, and
  `_test_helpers.sh:56` neutralises a bash 5.2 interpreter default rather
  than a caller's option and is exempted by MARKER with a reason.

- **`cch_write_settings` makes a between-boot re-seed safe.** The real
  binary MIGRATES `.claude.json`'s `bypassPermissionsModeAccepted` into
  `settings.json` as `skipDangerousModePermissionPrompt` on first boot and
  deletes the original, so a scenario that rewrote `settings.json` between
  boots wedged the NEXT boot on the Bypass Permissions modal — forever, at
  `state=empty`, which reads as a timeout rather than a config error. Found
  while building `#724`'s control boot, which is the first scenario to need
  two boots with different settings.

### Changed

- **The inherited-root warn step now PRINTS the leaked rows, not just their
  paths (`#720`).** The artifacts self-attribute and nobody had read them:
  an `ng-usage.jsonl` row carries `verb`/`sub`/`origin`/`win`/`pid`/`ts`.
  This makes the next CI occurrence attributable; it does not attribute the
  recorded one, and `#720` stays open on that distinction.

- **A green that required a re-run is no longer readable as a first-pass
  green (`#748`).** Nothing in the nexus read GitHub's `run_attempt`.
  This is the programmatic half `#750` defers ("any future consumer that
  reads CI state programmatically — a watcher emit, `ng`, a dashboard
  section — inherits the same blindness"); `#750` covers the SLOW band's
  own run summary, this covers everything that reads CI *about* a head.
  `GET /actions/runs`, `gh run list` and the check-runs API all return only
  the **latest** attempt, so a band that concluded `failure` and was re-run
  to `success` **at the same sha** was byte-identical to one that passed
  first time — to every tool, every emit and every check in this repo. At
  head `d4df844f` the SLOW band did exactly that (`test-jupyter-service.sh`
  went red, then green on re-run) and read as clean; the red was found only
  by enumerating attempts by hand.
  - This is a **different** failure from the ones `#604`/`#628` cover, and
    the distinction is load-bearing. Those are species of *absence* —
    no run, or a run that reached no verdict — and are caught by
    enumerating that every expected band is named and `success`. A
    **replaced** verdict defeats that enumeration by construction: the band
    *is* named and *is* `success`. So it is reported as its own finding
    rather than folded into the existing ones.
  - `monitor/ci-observed-runs.jq` now carries `run_attempt` and `id`. This
    costs **zero** extra API calls — the field was in the payload
    `ci-signal.yml` already fetched, and the extractor was dropping it.
  - `monitor/ci-attempt-history.sh` (new) resolves what the *superseded*
    attempts concluded, one call per superseded attempt and none at all for
    the overwhelmingly common attempt-1 head. `run_attempt` says a retry
    happened; only this says what it replaced.
  - `monitor/ci-trigger-audit.py` gains `classify_attempts()` and exit
    code **6**: `REPLACED-VERDICT` when a superseded attempt concluded
    `failure`, `ATTEMPTS-UNKNOWN` when its conclusion could not be read.
    A retry over a `cancelled` attempt replaced no verdict and is a stated
    **note**, not a finding. Exit 6 ranks *below* `FAILED`, so it carries
    the narrow meaning "the check set is otherwise clean and the thing
    wrong with it is the retry".
  - Absence of the attempt column reads as **UNSUPPLIED**, never as
    attempt 1 — otherwise the audit would print "each of those greens is a
    first-pass green" having looked at nothing, which is the detected
    defect wearing the detector's clothes. The positive claim is made only
    when provenance was actually supplied.
  - `ng ci-attempts <sha|branch|PR#>` (new) is the agent-facing half. The
    near-miss was not a PR gate failing — it was an agent reading `gh run
    list` at a head and concluding "green, merge it". This workspace's
    standard already says to enumerate CI "by name AND by attempt"; before
    this verb nothing did the second half.
  - `monitor/test-ci-trigger-audit.sh` grows cases 12–14 (16 assertions,
    31 → 47), including a negative control that neuters `classify_attempts`
    and confirms the new cases go green, and a stub-`gh` test asserting
    from the call log that an attempt-1 run costs no API call.

### Fixed

- **An Actions outage defeated every verdict guard at once, and the residue
  read as success (`#740`).** On 2026-08-06, PR `#739` carried zero
  check-runs at its head and presented as `mergeable=true
  mergeable_state=clean` — not pending, not blocked: *clean*. Every verdict
  guard this repo has built is **itself an Actions workflow**, so the outage
  disabled all of them simultaneously and the absence of evidence rendered
  as evidence of absence.
  - `ng ci-attempts` now **composes** the expected-band audit rather than
    punting it. That division was right about ownership and wrong about
    **reachability**: `ci-trigger-audit.py` is invoked from `ci-signal.yml`,
    which is a workflow, so the guard that would have caught the outage was
    among the things the outage stopped. `ng ci-attempts` is the only CI
    surface here that already runs **locally**, so it is where a merge-path
    reader can still get an answer. It shells out to the real
    `ci-trigger-audit.py` — nothing is reimplemented, and trigger semantics
    plus the `#628` verdict invariant keep their single owner.
  - **The zero case was never the dangerous one** — an empty run list was
    already a loud refusal here. The silent case is a **partial** set: some
    bands ran, all of them green, the missing ones invisible. "Every
    completed run is a first-pass success" is *true* and reads as approval.
    That case now exits **4**.
  - **An empty set has three causes and they no longer collapse**: the
    provider was down (bands expected, none ran → rc 4); the triggers
    genuinely select nothing (rc 4, stated as a sentence — untested on
    purpose is still untested); and *I could not look* (no PR context, so
    "no runs" cannot be separated from "no runs were expected" → rc 2,
    UNDETERMINED). Reporting these as one number would have been this
    repo's dominant defect class reproduced inside its own remedy.
  - Workflows are read **at the head sha** (local objects, then the contents
    API, then a refusal) — never from whatever this clone has checked out.
    Auditing a head against another revision's triggers would answer a
    question about the wrong tree.
  - **Two enumeration guards**, because a count that reads clean is a claim
    about the tally and not about the enumeration. The runs page is compared
    against the API's `total_count` (`per_page=100`, nothing paginated), and
    the PR's file list against `changedFiles`. A short file list would
    silently *shrink* the expected set, turning a missing band into a band
    that was never expected. Both refuse rather than report a subset.
  - The coverage boundary is declared **in the verdict**, where the reader
    forms the belief, not in a docstring: a bare sha says in so many words
    that the expected-band audit did not run and that a workflow which never
    fired would be invisible.
  - New `monitor/test-ci-head-attempts.sh` (8 cases, auto-discovered by the
    unit band). Mutation-validated: ignoring the audit in the verdict reddens
    the partial case, collapsing the empty-set causes reddens two, dropping
    the truncation guard reddens one. Exercised additionally against **real**
    heads — `d4df844f` (documented retry-over-red → rc 6) and PR `#753`
    (complete CI → cleared).
  - Note on provenance: the historical outage state is **no longer
    reproducible**. Actions has since backfilled `1d00aa71`, which now
    reports 5 workflow runs and 16 check-runs where the issue recorded zero.
    The zero-observed cases are therefore exercised on fixtures, and this
    change reproduces the outage's *shape*, not the outage.

- **The `cc-auto-update` deployment gate measured staleness against a
  branch fixes do not land on (`#754`).** PRs on this repo merge to the
  integration branch; `main` lags it by weeks. Re-measured on the live
  primary at `HEAD=f0c9510`: **5** commits behind `origin/main`, **23**
  behind `origin/dev`. Among those 23 was the `#747` merge installing
  `monitor/_pane-live.sh` — the `#745` guard whose absence lets a watcher
  paste into a dead orchestrator pane kill the tmux server, and with it
  (`bwrap` PID 1 under `--die-with-parent`) the whole sandbox. The gate
  reported "5 behind, proceed" about a clone missing the guard that makes
  the restart it authorizes survivable; a hand-set durable hold is what
  actually caught it.
  - The gate no longer implements its own staleness check. It delegates to
    `_clone_drift_probe` (`#620`), which the watcher's clone-drift detector
    already used and which was already right. **Two mechanisms answering
    "is this clone stale" was one too many** — the wrong one was the only
    one consulted at apply time. This is the collapse, not a second
    correction.
  - That fixed **two further defects of the same shape**, neither reported.
    (1) The old `rev-list HEAD..origin/main` ran after a best-effort
    `fetch … || true`, so a failed fetch left it answering **confidently
    from a stale remote-tracking ref** — measured on a fixture: it reported
    `behind=5` as fact when the true distance was **11**. The probe resolves
    the tip from a live `ls-remote`, so a failed fetch degrades the *margin*
    to `unknown`, never the *verdict* to a wrong number. (2) `behind=unknown`
    was gated behind `[[ =~ ^[0-9]+$ ]]`, so "could not measure" emitted **no
    WARN and no notification at all** — indistinguishable from "up to date".
    That is `#740`'s thesis living inside `#754`'s gate, and it is now a
    distinct, loud third state.
  - The remediation string names the ref it measured. Following the old
    `pull --ff-only origin main` landed the operator on a two-week-old tree
    that **still lacked the guard the WARN was about**.
  - The branch is **resolved, not hardcoded** — config
    `monitor.clone_drift.branch` (default `dev`), the repo's single existing
    record of the property, read rather than duplicated. Hardcoding `dev`
    would have been the same proxy one branch over. The key's name is
    historical and now under-general; renaming it is a config migration for
    every operator clone and is deliberately not bundled here.
  - Audit rows carry `behind_integration=<n|unknown> integration_branch=<b>
    drift=<up-to-date|behind|unknown>` in place of `behind_main=<n>`, so
    historical rows stay unambiguous under the new semantics.
  - Four regression cases in `monitor/watcher/test-cc-auto-update.sh`, each
    written to fail against the old code and each verified non-vacuous by
    mutation: reverting to `main` reddens 4 assertions, restoring the
    stale-ref read reddens 1, dropping the loud-`unknown` arm reddens 1,
    hardcoding `dev` reddens 1. A test asserting only "some number is
    emitted" would have passed the original bug.


- **The `gh` wrapper now selects a client by CAPABILITY, not by identity
  (`#755`).** `monitor/ghwrap/gh` resolved the real client as *"the first
  `gh` on `PATH` that is not THIS wrapper"* — an identity criterion asked
  to carry a capability guarantee it never made. Two clients are installed
  on the operator's host, `/app/bin/gh` **1.13.0 (2021-07-20)** from the
  agent-sandbox base image and `~/.linuxbrew/bin/gh` **2.89.0**, and which
  one won was decided by PATH ordering. Resolution now prefers the first
  candidate meeting a declared floor (`NEXUS_GH_MIN_VERSION`, default
  `2.86.0`), implemented in the new `monitor/gh-capable.sh`.
  - **Measured divergence, same job, same bot token, 2026-08-07.** Three
    surfaces degrade SILENTLY at 1.13.0 — rc 0, nothing on stderr:
    `run view --job <id> --log` returns **zero lines** (2.89.0: 622);
    `run view <run> --log` returns **two of the run's ten jobs** in a
    plausible-looking 1456-line output (2.89.0: all ten, 5448 lines); and
    `pr checks` prints **`pass` for a check whose REST conclusion is
    `skipped`**. The middle one is worse than empty because it looks
    complete. The third is a verdict misreport on exactly the distinction
    `#628`/`#740` exist to preserve — `skipped` and `cancelled` are not
    `success` — laundered before any enumeration sees it.
  - **`gh api` is unaffected**, byte-identical across both clients on every
    REST and GraphQL probe. That matters for scope: `gh api` is the
    repo's dominant call shape (117 of ~1,050 call sites, and the only one
    on any CI-reading path), so **no executable code path in this repo was
    exposed**. The exposure is ad-hoc agent invocation — which is how the
    defect was found, triaging `#744` — and that is precisely why the
    remedy lives in resolution rather than in patched call sites.
  - **The floor is a declared PROXY, and the file says so.** `#755` is an
    issue about identity standing in for capability, and a version number
    is also an identity claim; the honest defence is that it is *licensed
    by the measured table above* rather than by a changelog, and that the
    alternative which looks more like capability is blind to the headline
    case — both clients advertise `run view --log` in `--help`, so
    help-text probing cannot see the advertised-but-broken class at all.
  - **Coverage boundary, on the axis the mechanism varies on.** FIVE clients
    are installed on this host and all five were measured against one 10-job
    run, counting the jobs `run view --log` returns: `1.3.1` **0/10**,
    `1.13.0` **2/10**, `2.14.7` **2/10**, `2.86.0` **10/10**, `2.89.0`
    **10/10**. The first draft set the floor at `2.0.0` on two data points and
    was **wrong**: the truncation is not a 1.x defect, and `2.0.0` would have
    vouched for `2.14.7` — issuing the very false capability guarantee this
    change exists to stop. The floor is therefore `2.86.0`, the oldest version
    measured correct. Measured bad `<= 2.14.7`; measured good `>= 2.86.0`;
    `2.15`–`2.85` **unmeasured** and excluded, because being too strict costs a
    warning while being too lax silently vouches for a truncating client.
  - **Two of those five report `gh version DEV`** — no parseable number — and
    they sit at opposite ends of the capability range (`1.3.1` returns nothing,
    `2.14.7` truncates). That is the version proxy failing in the wild, and it
    is why an unreadable client is taken **in place** and reported
    `unverified` rather than stepped over: skipping would change which binary
    runs on the strength of a silence.
  - **Availability is preserved deliberately.** The wrapper never refuses
    over version: it is on the path of every agent and the watcher, on a
    nexus that cannot be restarted, so a below-floor host degrades to the
    old behaviour plus a throttled stderr warning and a durable breadcrumb
    at `monitor/.state/gh-below-floor`. The stderr nag is rate-limited
    (`NEXUS_GH_STALE_NAG_SECS`, default 300) because a per-call banner
    would be captured as data by the corpus's many `gh … 2>&1` sites — the
    warning must not become an instance of the class it warns about.
  - **`assert-shims-wrapped.sh` gains a version-floor leg** that measures
    the EFFECTIVE client end-to-end (a bare `gh --version` in a spawned
    probe shell, through the real wrapper) rather than scanning PATH for a
    capable binary — the proxy would have passed on the host where `#755`
    was observed, since 2.89.0 was installed the whole time. It **warns by
    default** and refuses only under `NEXUS_REQUIRE_GH_FLOOR=1`, because a
    refusal here also reaches `_respawn.sh`'s 78 and would stop the board
    self-healing (the blast radius PR `#670` documents). An unreadable
    version is a WARNING, not `79`: the guard *did* examine its subject,
    which is the boundary that file already draws for the nproc leg.
  - New suite `monitor/watcher/test-gh-capable.sh` — 45 assertions, count
    asserted, six seeded mutants (including a revert to identity
    resolution) each shown to redden it. It fakes the version axis with
    stubs, so it verifies resolution and gating logic only; the
    behavioural claims above are host measurements and are **not**
    reproducible on a runner, which has one `gh` and no `/app/bin`.

- **`test-jupyter-service.sh`: a timed-out precondition no longer reports
  as a product regression, and the blocking band's deadline scaling is no
  longer inert (`#749`).** The `d4df844f` failure printed four lines, of
  which only two were the timeout:

      FAIL: server back on a new port (deadline 20s)
      FAIL: env port moved past the squatter — got 0 want 1
      FAIL: healthy again after rotation (deadline 20s)
      FAIL: rotation forced exactly one restart — got 2 want 3

  `wait_for` returns 1 on timeout and the script carries on, so the
  *dependent* assertions sampled stale state and failed on their **values**.
  "rotation forced exactly one restart — got 2 want 3" reads as broken
  rotation logic; the rotation had simply not happened yet.
  - A `blocked_by` helper now skips dependents whose precondition timed out
    and reports them as `NOT EVALUATED (precondition timed out: …)`. The
    assertion **count is preserved** — one outcome per dependent, exactly as
    if it had run — so the suite cannot be quieted by breaking it earlier.
  - `th_deadline()`'s scale is CPU **oversubscription**, `ceil(jobs/nproc)`.
    The SLOW band passes no `--jobs` and exports no `NEXUS_TEST_JOBS`, so
    `jobs=1`; on a 2-vCPU runner that is `ceil(1/2) = 1`. The `#558`
    machinery was **structurally inert** in precisely the band `#737` made
    blocking — a lever that looks engaged and is not, since the deadlines
    carry a comment saying they are scaled. Oversubscription was also the
    wrong axis: `d4df844f` failed at `loadavg 0.16`, an idle host.
    `tests-slow-integration.yml` now sets `NEXUS_TEST_DEADLINE_SCALE=2`.
  - **Why 2.** Polled deadlines cost zero wall-clock on a green run, so the
    only ceiling is the per-test `--timeout 600`: this file's deadlines
    total ~219 s unloaded, so scale 2 worst-cases at ~438 s (inside 600, a
    timing failure still reports as labelled per-assertion FAILs) while
    scale 3 worst-cases at ~657 s, tripping the timeout and collapsing that
    detail into a bare `TIMEOUT`. 2 is the largest scale that keeps a
    failure legible.
  - `run-tests.sh` now prints the **effective** `deadline-scale=` in its run
    header. A band that forgets the lever previously looked identical in its
    log to one that set it deliberately: `jobs=1` was printed, `nproc` was
    not, and the reader was left to do the division.

- **`ci-signal`: "no checks ran" is now a RED check with a name, not a
  silence (`#604`).** `on: pull_request: branches: [main, dev]` filters the
  PR's **base**, so a PR stacked on a feature branch matched no workflow,
  collected zero checks, and rendered identically to all-green — `gh pr
  view` reporting `MERGEABLE` with an empty `statusCheckRollup`, no red on
  the merge button, nothing to click past. `#593` sat in exactly that state
  and was caught only because a human noticed its check count looked unlike
  its neighbours'.
  - `.github/workflows/ci-signal.yml` runs on **every** PR into **every**
    base with no `branches:` and no `paths:` filter, so the check set is
    never empty.
  - `monitor/ci-trigger-audit.py` recomputes, from the workflow sources,
    which workflows *should* have gated this (base, changed-files) pair and
    compares that against the runs GitHub recorded — the property, not the
    proxy "at least one check exists" (which this very workflow would
    satisfy by construction). Two verdicts with different remedies:
    `TRIGGER-GAP` (paths match, `branches:` excludes this base — the `#593`
    shape) and `MISSING-RUN` (expected on every axis, no run). Unparsed
    input is REFUSED, never defaulted.
  - The audit checks **itself**: a `branches:`/`paths:` filter appearing on
    `ci-signal.yml` is reported as `SELF-BROKEN`, so the trigger-gap
    detector cannot be trigger-gapped out of existence.
  - **Retargeting a PR now re-runs CI.** Changing a base emits only the
    `edited` event, never `synchronize`, so the documented remedy for the
    trigger gap silently failed to trigger. `tests.yml`, `cc-harness.yml`
    and `docs.yml` now list `edited` and gate their jobs on the base having
    actually changed, so title/body edits cost no runner minutes.
  - `monitor/test-ci-trigger-audit.sh` replays the `#593` PR shape against
    the real workflow files and asserts it can never audit clean.

- **The suite can now run under CI's bash, and says so when it does not
  (`#610`).** No host in this workspace ships bash 5.x; CI runs only 5.2.
  That asymmetry already hid two defects — the `#597` fork-floor probe that
  collapsed to its lower bound (CI capped forks at 87 against a real floor
  of 566, every test then dying of `EAGAIN`; unreproducible on 4.4 *even in
  principle*) and `patsub_replacement` corrupting generated `gh` stubs.
  - `monitor/toolchain-bash.sh` builds and caches a sha256-pinned GNU bash
    (5.2 and 4.4.18 pinned) under `monitor/.state/toolchain/`. Measured, not
    assumed: ~2 minutes on this host.
  - `run-tests.sh` gains `NEXUS_TEST_SHELL` (the interpreter each test is
    actually launched with — refused, never silently substituted, if it is
    missing or not bash) and ends **every** run, green included, with an
    interpreter line: `interpreter parity: bash 5.2` when it matches CI's
    pin, or a `COVERAGE BOUNDARY` block naming what was not tested and how
    to close it. `--require-ci-parity` turns the declaration into a refusal.
  - `monitor/ci-bash-version` holds the pin, and `tests.yml` asserts the
    runner's actual bash matches it — so the boundary local runs declare
    cannot quietly become a lie when GitHub bumps its image.
  - A `bash-legacy` CI job runs the unit suite under 4.4 — the mirror
    direction, and the version this lab's hosts (including the one running
    the live watcher) actually execute.

### Fixed

- **`pane-state.sh`: an idle `tui: fullscreen` pane's `content_hash`
  churned on tmux 3.x, so stale engagement marks never expired
  (`<your-org>/nexus-code#573`).** Under fullscreen (alternate-screen)
  rendering the input box is pinned to the bottom and the padded gap above
  it periodically flashes a RIGHT-ALIGNED contextual nudge (`● <tip> ·
  /<cmd>`). It lands ABOVE the `❯<NBSP>` input row — inside the hashed
  transcript region — and is non-numeric, so the existing digit-strip never
  neutralised it; every blink moved the hash, refreshing the watcher's
  change-corroborated `operator-engaged` mark forever and pinning the window
  open. `_content_hash` now drops these nudges before hashing, keyed on
  RIGHT-JUSTIFICATION (a `●` pushed to the right edge by a large leading-space
  run, ≥32) — a `●` at column 0 OR any small indent (a code-fence line, a
  pasted TUI capture, a nested-list bullet) is real content and still moves the
  hash. Real transcript content is never right-justified, and measured indents
  are ~2–4 columns (deep nesting rarely >16), so nothing real reaches the
  threshold; the residual error is biased to the RECOVERABLE side (an
  implausibly narrow, <~48-column pane could leave a nudge under the threshold,
  merely holding a window open a cycle longer — never a kill). An absolute
  space count is used, not a width-relative midpoint, so the test is ASCII-only
  and locale-safe. Measured against the real binary via `monitor/cc-harness` on
  tmux 3.4: over 60 s of a genuinely-idle fullscreen pane the nudge was the
  ONLY moving region byte. The `cc-harness` `fullscreen` matrix cell
  (previously advisory, red on `dev`) now passes. No-op in the inline
  renderer, where the same nudges render below the input row.

- **`printf … | grep -q` assertions inverted their own verdict under
  `pipefail`.** `grep -q` exits the instant it matches without draining its
  input; the writer then takes EPIPE, and under `set -o pipefail` that
  becomes the pipeline's status — so the assertion reported FAILURE at the
  exact moment the thing it tested turned out to be TRUE. Confirmed from the
  `#598` merge run on `dev`: `test-interactive-sessions.sh` line 198 emitted
  `printf: write error: Broken pipe` and failed T8b while its own dump
  showed the awk upsert under test had produced exactly the right body — on
  a ~90-byte payload, passing on the serial re-run. All 36 instances across
  18 files are converted to `grep -q PATTERN <<<"$var"`, including seven in
  `monitor/spawn-worker.sh` and instances in `monitor/lit.sh`,
  `monitor/cc-auto-update-apply.sh` and the PreToolUse hooks, where a
  spuriously non-zero `if` takes the wrong branch in production.
  `monitor/watcher/test-sigpipe-assertion-lint.sh` blocks reintroduction and
  demonstrates the mechanism executably.

- **Worker wrap-up can deliver to the request/reply channel instead of a
  forced GitHub issue (`--reply-to`).** A worker spawned to answer a
  confined request-channel request — canonically a remote SSH client that
  filed a `kind=question` and wants DATA back, explicitly *"no repo
  modification needed"* — had exactly one sanctioned hand-off:
  `ng wrap-up <issue> <report>`, which requires an issue number and posts
  to GitHub. The reply half of the round-trip already existed
  (`ng request reply`, RFC Parts B+D); the gap was the worker wrap-up
  integration. Both halves are now wired, with the delivery surface chosen
  by the ORCHESTRATOR at dispatch — never parsed from a remote client's
  (untrusted) prose.
  - `monitor/spawn-worker.sh --reply-to <request-id> [--issue <n>]`. The
    id is resolved against the inbox **at spawn time** (exit 16 on unknown
    or already-terminal), so a typo fails at dispatch rather than an hour
    later when the worker discovers its answer has nowhere to go. `--issue`
    without `--reply-to` is refused (exit 17) rather than silently ignored.
  - A new `## Reply-to wrap-up override` section in
    `skills/nexus.worker-defaults/SKILL.md`, extracted the same awk way as
    the floor and injected *after* it with `<REQUEST_ID>` substituted. Read
    **only** in `--reply-to` mode: with no flag the composed prompt is
    byte-identical to the pre-flag behaviour — the load-bearing invariant,
    since `spawn-worker.sh` composes the prompt for every nexus worker.
  - `monitor/ng wrap-up --reply-to <id> <report> [--issue <n>]
    [--answer-file <path>]` extends the existing verb rather than forking a
    parallel path, so `report-check`, the skeptic gate, the action log and
    the window retain stay unified. Steps 1–3 (upload / issue comment /
    trigger rocket) are skipped unless `--issue` is given; a new step 2c
    delivers the answer via `request-channel.sh reply` (the channel is not
    reimplemented). The answer is `--answer-file` when given, else the
    report's **full** `## Summary` section, plus a footer naming the report
    and any GitHub artifacts. A failed delivery — or an empty answer body —
    FAILS the wrap-up: the requester is blocked on it, so a silent success
    would be the worst outcome.
  - Visibility without an issue: the request + reply files under
    `monitor/.state/requests/` (plus the byte-exact
    `replies/<id>/results.md`), the watcher's request emit, the unchanged
    `reports/` write-up, and a `wrap-up` action-log event carrying
    `reply-to=<id> channel=ok`. The window provenance record gains a
    `reply_to` field so the orchestrator can see which windows owe a
    channel answer.
  - Tests: `monitor/watcher/test-spawn-worker-reply-to.sh` (36 assertions,
    including a byte-identity check of the no-flag prompt against an
    independent reference composition) and
    `monitor/watcher/test-ng-wrap-up-reply-to.sh` (66 assertions, including
    zero-length `gh` and `upload-asset` captures as the "no GitHub
    artifact" evidence).

- **Read-only-filesystem guard: the watcher degrades instead of dying
  (issue 473).** Twice — 2026-06-29 and 2026-07-09 — the project tree
  went read-only inside the sandbox mount namespace and the watcher
  disappeared without a word. Both incidents run the identical script:
  `version_check` sees drifted sources → `launcher.sh --replace` →
  SIGTERM the incumbent → the successor dies in `>>"$LOGFILE"`, a fresh
  `open()`, *before `main.sh` executes one line* → "did not publish a
  live pidfile" → silence. The incumbent it replaced was fine: it held
  its log fd from before the remount and had been logging normally
  throughout. That asymmetry — an open fd survives its mount being
  detached, a fresh `open()` does not — is why the outage was invisible
  from the inside, and it is the constraint every part of this change
  is built around.
  - `monitor/_fs_probe.sh` — ONE canonical probe (`nexus_dir_writable`,
    `nexus_path_writable`), sourceable and a CLI. It performs a
    create+unlink of a **new** path on **every** call. Never a cached
    fd, never a `stat`: a probe that appends to a held fd reports
    *healthy* during a total outage, which is strictly worse than no
    probe at all.
  - `monitor/watcher/_fs_guard.sh` — a per-cycle probe in the watcher
    loop. On failure the watcher enters **read-only degraded mode**: it
    suspends every project-tree write, keeps its loop alive (a live
    watcher is what notices recovery), and escalates **exactly once**
    per incident over channels that need no filesystem write
    (`sandbox-notify` → a GitHub incident issue via `mint-token.sh`,
    whose cache lives on a different mount → a tmux paste). The
    fire-once latch is in memory, deliberately: there is nowhere to
    write a rate-limit cursor, and the process dies with the incident.
  - **`launcher.sh` no longer decapitates.** `--replace` probes first
    and refuses on a read-only FS, leaving the working incumbent alive;
    `_version_restart_self` suppresses the self-restart for the same
    reason. If a watcher must nonetheless cold-start on a read-only FS,
    the launcher redirects its output to `$TMPDIR` so it *starts*,
    discovers the condition, and reports it — rather than dying in its
    own log redirect.
  - **Durable trace on recovery.** The 2026-06-29 incident left no
    record and was re-diagnosed from scratch ten days later. On the
    recovery edge the watcher appends the incident (duration, onset
    bounds, escalation channels used) to `.state/fs-incidents.jsonl`
    and comments the resolution on the open incident issue.
  - **`svc.sh status` leads with the truth**: a first-class
    `fs <OK|READ-ONLY>` row *above* the per-service rows, and a
    non-zero exit when read-only. It previously printed `UP` services,
    and exited `0`, while nothing in the workspace could save a file.
  - **The `PreToolUse` pending-tool hook fails OPEN**
    (`monitor/hooks/pending-tool-record.sh`). It was an inline redirect
    into the project tree whose non-zero exit blocked the tool call, so
    a storage hiccup became a total `Bash`/`Write`/`Edit` outage for
    every hook-gated worker. It is bookkeeping, not a security
    boundary: it warns and gets out of the way.
  - The operator-facing escalation message now leads with the remedy,
    quotes the discriminating evidence (mount `ro` over an `rw`
    superblock; the project's read-write bind absent from the
    namespace), states that no data is lost and that the filer is
    healthy so storage-support need not be paged, says what a restart costs,
    and never suggests remounting or `unshare`-ing around a
    kernel-enforced sandbox. It no longer asserts an NFS-flap root
    cause, which was never established.
  - `monitor/watcher/test-fs-guard.sh` — T1–T10, both directions.

- **Worker respawn on recovery (`bootstrap-recover.sh` step 3 +
  `--no-workers`).** Boot recovery now also respawns the worker
  agents that were active in the last watcher snapshot
  (`.state/last-snapshot.txt`, `--- tmux ---` section), via the
  canonical resume surface `spawn-worker.sh --resume <window>`
  (issue 197) — never a hand-rolled `claude --resume`. A snapshot
  window qualifies iff it is not infra (`orchestrator`, `services`,
  `watcher`, registry-named legacy service windows excluded), it has
  a `spawn` event in `.state/action-log.jsonl` (recovery only owns
  nexus-spawned workers), and that `spawn` is its latest lifecycle
  event — a later `wrap-up` / `window-close` means the worker already
  handed off, and the orchestrator's dispatch loop owns continuations
  of wrapped work. Idle-but-unwrapped workers ARE respawned.
  Idempotent (already-alive windows never double-spawned), bounded
  (`recover.max_workers` config, default 12, excess skipped with a
  loud notice), loud-on-skip (unresolvable sessions are logged, never
  fatal). Flag matrix: default = watcher + services + workers;
  `--no-services`/`--watcher-only` (core-only) also skips workers;
  the new `--no-workers` skips only the worker respawn;
  `--services-only` skips just the watcher. `boot-recover.sh`'s
  health gate now also fires on the `would resume` dry-run marker.
  Tests: `watcher/test-bootstrap-recover.sh` (worker identification +
  inclusion criteria, idempotency, flag matrix, unresolvable-session
  skip, cap), `watcher/test-boot-recover.sh` (worker-only-need gate).
  (issue 198)

- **Core-only startup flag (`--no-services`).**
  `monitor/bootstrap-recover.sh --no-services` (synonym:
  `--watcher-only`; also reachable as `monitor/svc.sh up
  --no-services`) brings up the nexus core alone — the watcher, which
  then revives the orchestrator via its own liveness machinery — and
  skips every service registered in `services.registry`. Idempotent
  like the rest of recovery; combining it with `--services-only` is
  rejected with a clear error (exit 1) since together they would
  recover nothing. `svc.sh up` now propagates a nonzero
  `bootstrap-recover.sh` exit instead of swallowing it. Tests:
  `watcher/test-bootstrap-recover.sh` (core-up with zero services,
  healthy-stack no-op, bad-combo rejection),
  `watcher/test-svc.sh` (`up --no-services` pass-through + failure
  propagation). (issue 195)

- **JupyterLab as a service (`monitor/jupyter-up.sh` +
  `skills/nexus.jupyter`).** One idempotent command turns a project's
  [labsh](https://github.com/katosh/labsh) JupyterLab into a
  registry-managed service: ensures a project kernel (`labsh kernel
  add`, or `--venv DIR` → `labsh kernel register` for existing/Lmod
  venvs), maintains a `jupyter-<project>` row in `services.registry`,
  and launches `monitor/labsh-supervised.sh` (a watchdog that bounces
  unhealthy servers, follows labsh's port auto-increment via
  `.jupyter/labsh-service.env`, adopts hand-started servers, and runs
  `labsh stop` on TERM) through `recover_service` — so
  `bootstrap-recover.sh` revives it on boot and `svc.sh` manages it.
  `monitor/jupyter-health.sh` is the shared authenticated healthcheck
  (`/api/status` with the project token; token rotation self-heals via
  a supervised bounce). `--down` deactivates (stop + deregister),
  `--status` reports. The `nexus.jupyter` skill encodes the foolproof
  default: a bare "jupyter session" request → `jupyter-up.sh <dir>`,
  then `labsh kernel exec/inspect` per `<yourlab>.labsh`. Tests:
  `watcher/test-jupyter-service.sh` (hermetic stub labsh) and
  `watcher/test-integration/test-jupyter-service-real.sh`
  (`RUN_INTEGRATION=1`, real servers/venvs/kernels in throwaway `/tmp`
  projects). (issue 184)

### Changed

- **The shim precondition gained a THIRD outcome: `exit 79`, "NOT
  CHECKED" (<your-org>/nexus-code#612).** `monitor/assert-shims-wrapped.sh`
  used to return `0` in three states where it had examined nothing at all —
  `NEXUS_ROOT` unset, no `monitor/*wrap` shim dirs anywhere, and no probe
  shell — so "the check did not run" and "the check ran and was clean"
  were the same observable value. That is the defect class the guard exists
  to close, reproduced inside the guard. Those three now exit `79`, which
  every launcher's emitted guard block (`monitor/guard-block.sh.in`)
  records as a durable `NOT CHECKED` row in
  `monitor/.state/guard-unverified.log` and then ALLOWS — the caller
  decides, and `NEXUS_REQUIRE_SHIM_CHECK=1` escalates it to a refusal (78).
  A CONFIRMED failure still outranks it: a run where one leg was
  unexaminable and another FAILED exits `1`.
  - The contract lives in `assert-shims-wrapped.sh`, **not** in the
    deprecated `assert-gh-wrapped.sh` forwarder. The block searches the
    generalised name first, so a third outcome implemented in the forwarder
    would have been unreachable dead code with every suite still green.
  - Explicit caller opt-outs (`NEXUS_ASSERT_SKIP_SHIMS`,
    `NEXUS_ASSERT_SKIP_NPROC`) deliberately do **not** produce `79` — a
    caller that disabled a leg already knows. That bound is asserted, along
    with the fact that no launcher sets either flag.
  - Two suites now pin this, on deliberately **disjoint** contracts:
    `test-assert-shims-wrapped.sh` pins the exit code across every route
    into each condition (including the no-override route a real launcher
    takes), and `test-spawn-guard-fail-closed.sh` pins the consequence —
    the durable row, the escalation, and forwarder equivalence. The split
    is the point: an implementation was demonstrated that satisfied both
    of the pre-existing suites at once by branching on which override
    variable the fixture had set, because both were reading the same
    observable.

- **`ng lit search`'s zero-result relaxation probe is now
  order-invariant: leave-one-out over the query's canonical content-term
  set, replacing the positional six-word prefix.** The prefix made a
  logically commutative conjunction land on different branches depending
  on where its terms happened to sit: the same eight terms, same corpus,
  same ground truth (a real zero) gave `status: error,
  query_over_constrained, exit 2` in one wording and a clean `status: ok,
  count: 0, exit 0` in another. The probe now builds its relaxations from
  `_probe_terms` — tokens lowercased, punctuation-trimmed, stopwords
  dropped, deduplicated, `LC_ALL=C` sorted — so every probe query, the
  order the drops are tried in, and therefore the verdict, are functions
  of the term SET. Permuting a query changes nothing but the echoed
  `query` field; so does re-casing it, punctuating it, or padding it with
  stopwords.
  - **Leave-one-out says more than a prefix could.** A drop is the
    closest query to the one asked that still hits, so a hit NAMES the
    binding term and the remedy is that near-query — where the prefix
    steered the caller at a broader question than the one they asked
    (`#600` item 4). When nothing hits, the claim is narrower and honest:
    no single term among those tried explains the zero.
  - **Cost, stated rather than hidden.** Up to `LIT_PROBE_MAX_DROPS` (6,
    env-tunable) requests on the zero-result path, early-exiting at the
    first hit; the old probe cost one. The cap is a real coverage limit —
    a drop sorting past it is never tried — so `probe.drops_tried` /
    `probe.content_terms` report the coverage actually achieved, and a
    missed hit degrades to the hedged zero rather than a confident one.
  - **The burst is paced** (`LIT_PROBE_DELAY_SECS`, 1s, never before the
    first drop). Fired back-to-back against the real S2 the drops earn
    `Too Many Requests` where the old single-request probe did not,
    degrading a would-be clean zero to `partial` / probe `inconclusive`.
    Found by running the changed binary against the live backend, not by
    inspection.
  - **The probe establishes a DROP-ZERO BASELINE before naming any term.**
    The reduction differs from the caller's query by more than the dropped
    term — stopwords are gone too — so when a stopword was the binding
    constraint the reduction ALONE already hits, the first drop hits
    trivially, and an arbitrary content term gets blamed. Measured:
    `… medulloblastoma without` was blamed on `cell`, while dropping
    `cell` and keeping `without` still returned 0. Disclosure could not
    cure this one, because the scoped claim ("X is the term whose removal
    recovered hits") is false when nothing needed removing. The probe now
    searches the unperturbed reduction first; if that hits, the verdict is
    `probe.reason: "reduction_recovered"` with `dropped_term: null` and
    the message says *no single content term accounts for this result* —
    which is the verdict a leave-one-out probe can actually support.
  - **A quoted phrase is not probed at all.** The probe rebuilds its query
    from content terms, which strips the quotes, and an un-quoted phrase is
    a strictly broader search — so on a phrase query *any* drop hits and
    the tool named whichever term it tried first. Reproduced against a
    phrase-aware stub: it blamed `aged`, and removing `aged` recovered
    nothing. A query containing a double quote now reports
    `probe.state: "inconclusive"`, `probe.reason: "quoted_phrase"` and
    claims nothing. The `_relax_probe` header claim ("varies only the one
    dropped term, so a hit is attributable to that term and nothing else")
    was false as written for the same reason and is now accurate.
  - **`_probe_terms` no longer depends on the ambient locale.** Trimming
    with `[^[:alnum:]]` meant that under `LC_ALL=C` awk treated every byte
    of a multi-byte character as non-alphanumeric: `γδ` vanished entirely
    and `α-synuclein` became `synuclein`, so the term set — and with it
    the `LIT_PROBE_MIN_TERMS` gate — changed with the environment. Trimming
    is now against an explicit ASCII list, with standalone Unicode
    punctuation dropped by whole-token match (a byte-wise trim would alias:
    the trailing byte of Cyrillic `М` is the trailing byte of `“`).
  - **New `probe` object on every search response** (`state` `not_run` |
    `hits` | `empty` | `inconclusive`, plus `reason`, `backend`,
    `content_terms`, `drops_tried`, `max_drops`, `dropped_term`, `query`).
    `reason` (`results_returned` / `too_few_content_terms` /
    `quoted_phrase` / `no_backend_available` / `backend_error`) keeps the
    non-verdict states from repeating the ambiguity below. This also
    resolves `#600` item 3: `partial` had two causes and the backend
    lists witnessed only one, so an unrunnable probe set `partial` with
    `failed_backends` **and** `skipped_backends` empty — a caller written
    to the documented contract found nothing wrong and concluded nothing
    was. `probe.state: "inconclusive"` is that case.
  - The probe threshold is now counted in **content terms** rather than
    whitespace words (`LIT_PROBE_MIN_TERMS`, still 7): a stopword is not
    what makes a conjunction too narrow, so it must not decide whether a
    zero gets corroborated. `#600` item 2 (a genuinely short query is
    still never probed) and item 5 (latency on the ASTA slow path, which
    this change makes worse in the worst case) remain open.
  - `monitor/watcher/test-lit-probe-order-dependence.sh` now pins the
    invariance it previously documented as an open defect (67 → 269
    assertions, with an assertion-COUNT floor so a helper that vanishes
    into rc 127 cannot pass silently), and six negative controls — every
    one consuming the live binary rather than a fixture's copy of a format
    string. Three are new: the equality predicate
    fed a differing term set must fail, and a copy of `lit.sh` with the
    canonicalising sort removed must diverge end to end on a permuted
    pair — without the latter, "the two orderings agree" is also what a
    probe that never fires would look like. No claim assertion changed:
    "no ordering certifies a zero" was written to be independent of which
    branch a query lands on. (issue `#600`, from the PR `#596` skeptic
    review, finding F1)
- **Work-root JupyterLab service renamed `jupyter-workroot` →
  `jupyterlab`; cockpit shows the tokened URL; `logs` includes the
  server's output.** The single root service registered by
  `jupyter-up.sh --root` (and advertised by the `svc.sh` cockpit when
  dormant) is now plainly `jupyterlab`; `--root` activation migrates a
  leftover legacy `jupyter-workroot` row in place (stops/cleans its
  supervisor, re-registers under the new name — a stale row is never
  fatal). The cockpit's `DETAIL` column, now the final untruncated
  column (the seldom-useful `WINDOW` column is gone), renders an UP
  labsh service's reachable, directly-openable URL —
  `http://<fqdn>:<port>/lab?token=…`, FQDN-rewritten on external binds
  (issue 252's rule), degrading to the bare URL when no token is
  resolvable and never erroring the cockpit. `svc.sh logs <name>` and
  the cockpit log split tail the jupyter server's own stdout
  (`.jupyter/labsh.bg.log`, which prints the access URL on startup)
  alongside the supervisor log. (issue 191)

- **`./watcher` retargeted to the unified headless start; upgrade is
  self-delivering.** The user entry point (`monitor/watcher/entry.sh`;
  new alias symlink `./nexus`) no longer hosts the watcher in a
  window or spawns the orchestrator itself: it self-checks (tmux +
  agent-sandbox), brings the stack up via `monitor/svc.sh up`
  (headless watcher + registry services; the watcher then spawns the
  orchestrator), and leaves the invoking window running the `svc.sh`
  cockpit (window name `services`). `--continue` is reconciled onto
  the orchestrator session-id pin
  (`monitor/.state/orchestrator-session-id`): the default boot
  archives the pin (timestamped, never deleted) so the cold start is
  fresh; `--continue` keeps it so the watcher resumes that exact
  session via `claude --resume <sid>` — without a valid pin the
  watcher spawns fresh, never `claude --continue` (issue 200).
  Additionally, a watcher that starts under **legacy window hosting**
  (`WATCHER_WINDOW != headless`, the launcher's marker) now surfaces
  a one-shot `--- watcher hosting migration ---` notice in its
  startup-sweep emit — converge steps: pull BEFORE restart, then
  `monitor/svc.sh restart watcher` — and keeps operating normally
  (new module `monitor/watcher/_hosting_migration.sh`). New page
  [`docs/operating/upgrading.md`](docs/operating/upgrading.md)
  documents the mechanism and the manual checklist; the windowed-era
  descriptions across `README.md`, `docs/`, and `monitor/README.md`
  were swept to the headless model. (<your-org>/<your-nexus> issue 182)

- **Watcher folded into the services model — headless, no tmux
  window.** `watcher/launcher.sh` now launches `main.sh`
  `setsid`-detached with stdout/stderr appended to
  `monitor/.state/watcher.log`, verifies the self-published pidfile
  before reporting success (exit 3 on a spawn that didn't stick), and
  sweeps a leftover legacy `watcher` window on the next spawn.
  `_watcher_alive` / `_watcher_reason` drop the tmux-window-presence
  check (pid identity + heartbeat age are the whole story; the
  window parameter is retained-and-ignored for arity compatibility).
  `ng watcher-status` reports `hosting: headless` and flags a legacy
  window. The canonical bounce is `monitor/svc.sh restart watcher`
  (== `launcher.sh --replace`); `--window`/`--force` are accepted
  but ignored. The cockpit tails the watcher log via key `0` /
  `svc.sh logs watcher`.

- **`svc.sh` grew into the stable stack surface.** Flicker-free
  in-place repaint; log picks no longer steal focus (the
  `select-pane -T` titling side effect); single-key controls;
  pinned core rows (watcher tri-state liveness, orchestrator window
  + turn-end heartbeat). New explicit verbs: `status` / `up`
  (idempotent whole-stack bring-up via `bootstrap-recover.sh`; the
  watcher then spawns/revives the orchestrator) / `start` / `stop`
  (process-group TERM, KILL escalation, loud warning if the
  healthcheck survives) / `restart` / `logs`. Sandbox-agnostic by
  design — prefix `agent-sandbox` explicitly when wanted.

- **Respawn hardening after the 2026-06-02 false-positive-respawn +
  watcher-death incident.** Two root causes, both fixed:

  - **Target-absent respawn now requires confirmed absence.**
    `monitor.agent_missing_respawn_delay` default raised 0 → 3 (four
    consecutive absent observations at the 2 s probe cadence, ~8 s),
    and a new pre-launch re-verification
    (`_respawn_verify_target_absent` in `monitor/watcher/_respawn.sh`)
    runs at the moment of decision: a fresh window probe, a pane scan
    for a live orchestrator process (identified via the
    `NEXUS_IS_ORCHESTRATOR=1` environment marker, with tmux
    rename-race healing), and a liveness-signal comparison against
    the absent-streak start each independently abort the respawn.
    Aborts are logged and action-logged
    (`respawn-aborted-reverify`).

  - **A false-positive respawn can no longer take the watcher down.**
    The recovery prompt pasted into a respawned orchestrator used to
    instruct it to *kill the watcher* when it discovered the respawn
    was wrong — which is exactly what happened on 2026-06-02, leaving
    the workspace unmonitored. The prompt now mandates a stand-down
    protocol scoped to the duplicate itself: restore the original
    agent's window name, record the false positive, and remove ONLY
    the duplicate's own window (by window id). It explicitly forbids
    killing the watcher, the tmux session, or any other window. The
    watcher additionally traps SIGHUP to log its own demise
    (attributable post-mortem instead of a clean log tail) and to
    release its pidfile/lock on `tmux kill-window -t watcher`.

- **Watcher / orchestrator rethink** (issue #72; closes the seven
  detection regressions catalogued there). Five coordinated
  changes shipped together so we don't re-introduce the
  brittle-layering problem the meta-issue diagnosed:

  - **Classifier hardening.** `pane-state.sh` now distinguishes
    `empty` (renderer transient — claude alive in the pane's
    process tree) from `absent` (no live claude). Probe-side,
    `_idle_probe.sh` maps only `absent` and `blocked` to the
    inviolable `pane-absent` class; `empty` becomes a
    skip-and-retry-next-cycle signal. Closes regressions 1 + 2.

  - **Lifecycle anchors.** `monitor/spawn-worker.sh` writes an
    authoritative `spawn` action-log event AND seeds the
    engagement-log with epoch=now at window creation. The idle
    probe's wrap-up matcher scopes candidates to entries newer
    than the current-lifecycle spawn ts, so a stale wrap-up from
    a prior life of a recycled window-name (or from before
    `claude --continue`) drops out automatically. New knob
    `monitor.idle_pool_spawn_grace_seconds` (default 120s) guards
    the gap between `tmux new-window` and `claude` actually
    starting. Closes regression 3.

  - **Retain persistence.** `spawn-worker.sh` and
    `respawn_agent` set `tmux remain-on-exit on` at window
    creation. The pane survives a claude exit so the operator
    can revisit a retained worker's transcript and pane-state.sh
    can classify the post-exit pane as `state=absent` instead of
    the window vanishing silently. Closes regression 5.

  - **Emit completeness.** Every emit now starts with a one-line
    workspace prelude (`N busy | N idle | N retained | N
    idle-too-long | N pane-absent`). New section
    `--- workspace snapshot ---` lists every tracked worker
    window with its current pane-state and idle-age; force-
    included on emits hitting the configured cadence
    (`monitor.full_state_emit_interval_seconds`, default 600s)
    AND on the startup-sweep emit. Pure-cadence emits are tagged
    `poll-full-state` in the archive. Transition emits in
    between stay narrow. Closes regression 6.

  - **Decision helpers.** New verbs `ng spawn-decision <window>`
    (advisory continue-vs-spawn classifier) and
    `ng wrap-up-check <window>` (verifies a worker has completed
    its hand-off obligations before close). Both mirror the
    policy in `skills/nexus.window-cleanup`. Tests under
    `monitor/watcher/test-ng-spawn-decision.sh`.

  New config knobs:
  `monitor.idle_pool_spawn_grace_seconds` (default 120),
  `monitor.full_state_emit_interval_seconds` (default 600).
  Existing knobs unchanged; full back-compat for legacy windows
  with no spawn-event anchor.

  - **Per-spawn Claude Code hook scaffolding.** `spawn-worker.sh`
    now extracts the JSON block following the
    `<!-- worker-hooks-default -->` marker in
    `skills/nexus.worker-defaults/SKILL.md` and (when non-empty)
    writes it to `/tmp/spawn-hooks-<window>.<pid>.json`, passing
    `--settings <path>` to claude. The launcher trap-cleans the
    file on exit. Default block is `{}` so back-compat is the
    empty case — user-global hooks remain unaffected. Operators
    populate the block to apply nexus-wide hooks (heartbeat
    writes, notification surfacing, etc.) on every spawn. Hook
    schema, reliable events, and clobbering caveats documented
    in the SKILL's new `## Worker hooks` section. Tests in
    `test-spawn-worker.sh` cover both the empty-default
    (no `--settings`) and populated paths.

### Added

- **Docs site scaffolding** (`mkdocs.yml`, `docs/`,
  `.github/workflows/docs.yml`, `docs/requirements.txt`).
  mkdocs-material site auto-deployed to GitHub Pages on every
  push to `main`. Full content fan-out across five sections
  (Getting started, Operating, Admin, Reference, Contributing)
  follows in subsequent PRs. (PR #13.)
- **`ng wrap-up` verb** — one-shot end-of-task hand-off: upload
  report, post link comment, rocket trigger comment, log the
  event. Supports `--comment-body-file` for bespoke comment
  prose with `{{REPORT_URL}}` token expansion, `--no-comment`
  to skip the comment step, `--allow-stub` for intentional
  checkpoint wraps. Runs `ng report-check` as a pre-flight and
  refuses stub reports. (PR #4.)
- **`ng report-init` verb** — writes a frontmatter'd skeleton
  at the canonical
  `<reports-dir>/<project>_<YYYY-MM-DD>_<HHMMSS>_<slug>.md`
  path, capturing session-id + tmux window automatically.
- **`ng report-check` verb** — validates a report against the
  schema (frontmatter present, all five canonical sections,
  body ≥ `monitor.report_min_chars`, no placeholder markers).
  Used by `ng wrap-up` as pre-flight and by the watcher's
  idle-probe to classify `wrapped-but-stub`.
- **`ng fetch-asset` verb** — user-PAT bridge for fetching
  `github.com/user-attachments/...` URLs the bot's installation
  token can't reach. Writes bytes locally so the agent reads a
  file path instead of poisoning the session with a 404 on the
  attachments host. (PR #73 upstream.)
- **`ng reply --repo OWNER/REPO`** — cross-repo reply target;
  overrides the cwd-derived origin. (PR #4.)
- **Idle-worker probe** (`monitor/watcher/_idle_probe.sh`) —
  combines tmux's `#{window_activity}` with `pane-state.sh`
  classification to surface really-idle workers, classify them
  as `wrapped` / `no-wrap-up` / `wrapped-but-stub` /
  `idle-too-long`, and emit transitions to the orchestrator.
- **`pane-state.sh`** — distinguishes Claude Code's autosuggest
  ghost from real user input by ANSI escape inspection.
  Replaces eyeballing `tmux capture-pane` output. (PR #94
  upstream.)
- **GraphQL polling gate** — bucket-floor + cadence gate
  before every GraphQL call so a single bad cycle can't burn
  the quota. (PR #70 upstream.)
- **Deliveries surface** — webhook-deliveries log as a primary
  comment source alongside the GraphQL surface; mentions search
  as a tertiary fallback. JWT minting for the deliveries
  endpoint. (PRs #62, #68 upstream.)
- **`nexus.window-cleanup` skill** — orchestrator-exclusive
  policy for closing worker tmux windows: triggers, retention
  overrides, pre-close report check, kill mechanism, cadence.
  (PR #101 upstream.)
- **`nexus.infra-review` skill** — periodic meta-review of
  `## Infrastructure Issues` sections across `reports/` into a
  ranked, deduplicated backlog.
- **Crash-loop guard** for the agent respawn path; bounded
  respawn rate with history file in `monitor/.state/`.
- **CI guard against report leaks**
  (`.github/workflows/check-no-reports-leaked.yml`) — fails any
  PR adding files under `reports/` except `reports/.gitignore`.
  (PR #3.)
- **`@<operator>` as default CODEOWNER reviewer** + `ng pr create`
  auto-`--reviewer` based on `github.user_login`. (PR #37,
  PR #36 upstream.)
- **Cross-fork discovery** — topic tag + issue-association in
  report slugs lets bots discover work across forks. (PR #71
  upstream.)

### Changed

- **Asset-repo cutover** — `monitor/upload-asset.sh` now uploads
  to the dedicated asset+issue repo's `main` branch rather than
  to the (deprecated) wiki. Per-operator state cleanly separates
  from the shared code repo. (PR #1.)
- **Watcher inverted as entry point** — `monitor/watcher/entry.sh`
  is now the user-facing entry; it brings up the `claude`
  orchestrator window from inside the watcher loop rather than
  the other way round. Cleaner startup ordering, fewer
  race conditions on `--continue`. (PR #92/#93 upstream.)
- **Worker safety floor** moved into
  `skills/nexus.worker-defaults/SKILL.md` and injected verbatim
  into every spawn prompt by `monitor/spawn-worker.sh`. Floor
  body slimmed ~30% by folding per-step hand-off into the new
  `ng wrap-up` verb.
- **Spawn prompts** carry an explicit `## Worker environment`
  header with absolute paths so reports in secondary clones
  (worktrees, fresh clones) still land in the primary's
  `reports/` dir. (PR #96 upstream.)
- **Report schema** now requires YAML frontmatter (`project`,
  `date`, `session-id`, `window`, `trigger`, `status`) on top
  of the five canonical sections.
- **GitHub-writes authorization** documented as three tiers
  (internal / user-public / external-public) with explicit
  per-action approval rules; the bot identity rule (`WHO`)
  separated from the per-write approval rule (`WHETHER`).
- **CLAUDE.md** slimmed substantially; orchestrator-only prose
  moved into `monitor/README.md` and `skills/nexus.*`. The
  top-level contract now fits on one screen.
- **Lockfiles** moved into `monitor/.state/lockfiles/` from
  workspace root. Independent-clones pattern adopted as the
  primary parallel-work convention; lockfiles persist as
  fallback. (PR #57 upstream.)
- **Overview-issue routing-only rule** — the pinned `Nexus`
  issue now carries only routing one-liners; content threads
  live on dedicated issues.

### Fixed

- **`ng lit search` no longer answers a failed search with `count: 0`.**
  (`#588`.) A search that did not establish anything returned a clean,
  well-formed empty result set — and to an agent `count: 0` is a
  substantive claim about the world, so it gets believed and written up as
  *"to our knowledge, no prior work addresses X."* An error is visible and
  gets retried; a confident zero gets cited. Measured live (2026-07-29):
  a 41-word on-topic query returned `count: 0`, `partial: false`, no failed
  backends and **exit 0**, while a 6-word prefix of the same query on the
  same backend returned thousands of hits.
  - Every response now leads with **`status`** — `ok` (every requested
    backend searched; a 0 means nothing matched the query as asked),
    `partial` (a backend failed
    or was skipped; a 0 establishes nothing), `error` (the query itself
    failed) — plus a one-sentence `summary` and a `complete` flag. The
    distinction is carried by the DEFAULT rendering, JSON and `--human`
    alike, not by extra fields a caller must think to read.
  - On `status: error` the response carries **no `count` and no `results`**
    (`.count` reads `null`, never `0`) and exits 2. A well-formed empty
    result set is exactly how a broken search gets read as an empty
    literature.
  - **Over-constrained queries are detected by measurement, not by a length
    guess.** Every backend ANDs the query terms, so a long query returns a
    real, well-formed zero with no distinguishing response field — S2's
    total for one on-topic query walked 8616 → 136 → 21 → 2 → 0 as it grew
    from 7 to 22 words, HTTP 200 throughout. So on a zero-result search of
    7+ words, `lit.sh` re-runs one probe with the query's first 6 words
    against a backend that already answered — automating the manual retry
    the reporter performed. Hits on the shorter query ⇒
    `error.kind: query_over_constrained`, naming the evidence and the
    shortened query to retry. The probe runs only on the zero-result path
    and can only escalate a zero, never suppress a hit.
  - **The probe corroborates; it never certifies.** Its prefix is the query's
    first six *whitespace tokens*, so its verdict is **order-dependent** —
    the same 8-term conjunction, re-worded, lands on either branch — and the
    prefix's result set is a *superset* of the full query's, so a hit shows
    only that the broad topic is populated. An earlier draft of this change
    therefore stamped one ordering with *"this is a genuine zero (confirmed:
    …)"* — reproducing the very `#588` shape with an endorsement the bare
    `count: 0` never carried. No zero is now labelled *genuine*, *confirmed*,
    or *verified* in any rendering; the summary reports the observation (and
    what the probe did or did not find) and leaves the inference to the
    caller, and `query_over_constrained` says a zero **may** reflect an
    over-specific query. Pinned by
    `monitor/watcher/test-lit-probe-order-dependence.sh`, which runs the
    counter-example in both word orders and carries a built-in negative
    control that re-asserts the old wording and observes the guard fail.
  - Further `error.kind`s: `query_too_long` (past OpenAlex's 1500-char
    ceiling — caught pre-flight, no request spent), `query_rejected` (a
    backend reported a query fault; unretryable, and it condemns the whole
    search since every backend answered the same bad query — previously
    miscast as an ordinary backend failure), and `no_backend_searched`.
  - **A genuine S2 zero is no longer reported as a broken backend.** S2
    answers a zero-hit search with `{"total": 0, "offset": 0}` — no `data`
    key at all — which was read as a malformed response, so every real S2
    zero surfaced as a phantom `failed_backends: ["s2"]`. The same defect
    in the opposite direction, in the same code path.
  - `partial` now means "not every requested backend contributed", so a
    backend **skipped** for want of a key counts, not only one that failed.
    Reporting `partial: false` for a `--source all` search that never
    queried S2 told the caller it had received everything it asked for.
  - Pinned by `monitor/watcher/test-lit-empty-vs-failed.sh` (74
    assertions), whose stub reproduces the measured backend behaviour
    (terms ANDed; ≤6 words match) so the probe path is exercised rather
    than simulated — including negative controls that a genuinely empty
    search still reports a clean zero with no warning, in both renderings.
- **`ng` `STATE_DIR` resolver** now picks up `NEXUS_ROOT` /
  `nexus.root` config so worker wrap-ups from worktrees land
  in the primary clone's `.state/`, not the worktree's. (PR #11.)
- **`ng wrap-up` tmux pane targeting** — the verb now records
  the source window explicitly instead of relying on the active
  pane, so wrap-ups from inactive windows are attributed
  correctly. (PRs #109, #12.)
- **`ng` session-id slug** — matches Claude Code's path
  normalisation so `ng report-init` recovers the right session
  log on re-runs from different cwds. (PR #107 upstream.)
- **`ng wrap-up --trigger-repo`** + write-verb precedence
  fixed so cross-repo triggers route their reaction to the right
  repo. (PR #108 upstream.)
- **Watcher idle-probe** passes window index to `pane-state.sh`
  rather than relying on the active pane. (PR #7.)
- **`_classify_diff` suppresses git-section diffs** so a worker
  branch-switch doesn't trigger a noisy emit. (PR #80 upstream.)
- **GraphQL detect-and-react cascade** — watcher classifies
  GraphQL rate-limit failures, mints a bot installation token
  rather than falling through to the user's exhausted PAT,
  and surfaces a sentinel emit so the orchestrator knows
  about the gap. (PRs #64, #63 upstream.)
- **Watcher emits on every eligible comment**, not just on
  snapshot diff — a missed paste no longer silently swallows
  a comment. (PR #63 upstream.)
- **Deliveries IDs extracted as strings** — `jq` 1.5 truncates
  the >2^53 integer IDs GitHub uses. (PR #68 upstream.)
- **`config/load.sh`** emits lowercase YAML booleans
  (`true`/`false`) rather than Python `str(True)`.
- **`_snapshot_pr_comments` MAX_NODE_LIMIT_EXCEEDED** — query
  node count brought below GitHub's GraphQL limit.
- **`mint-token`** anchors cwd via `BASH_SOURCE` so sub-project
  agents get a real installation token. (PR #30 upstream.)
- **`watcher: --continue` resume** — correct slug encoding;
  drop the positional prompt that conflicted with `claude`'s
  argv shape. (PR #97 upstream.)
- **Watcher fast-respawn** when the target window goes missing
  rather than emitting `rc=2` and stalling. (PRs #47, #51
  upstream.)
- **Watcher auto-unstick paths** for stuck permission prompts,
  rate-limit prompts, and transient API-error wedges (cases
  A/B/C in `_unstick.sh`). (PRs #42, #98 upstream.)

### Removed

- **Stray `reports/` file** accidentally committed in PR #40
  removed; CI guard above prevents recurrence. (PR #3.)
- **`context/` directory** — unused in practice.
- **`bipartite`/`bip` references** — superseded by `labsh`.
- **`🤖-prefix` convention** for bot comments — replaced by
  the rocket-reaction opt-out signal.

## Earlier history

The workspace was restructured into its current
agent-coordinated shape on 2026-04-14 (`54ab69b`). Before that
the repo was a personal research scratchpad with no monitor,
no watcher, and no bot. The first watcher prototype
(`monitor: tmux-hosted watcher with paste-to-target + diff
archive`, PR #12) landed on 2026-04-23; bot setup
(`docs: bot setup guide + permission rationale`, PR #15) the
same day. The `monitor/ng` CLI landed on 2026-04-17.

`git log --since 2026-04-14 -- monitor/ skills/ config/` is
the authoritative record of work prior to the asset-repo
cutover (2026-05-09).
