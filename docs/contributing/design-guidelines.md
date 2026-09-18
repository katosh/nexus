# Design guidelines

This page states the **one defect class** that dominates this
repository, names it, and indexes the executable doctrine that already
enforces it. It is for a change-author *before* the change — the
audience the doctrine did not previously have.

It exists because of a measured gap
([<your-org>/nexus-code#1264](https://github.com/<your-org>/nexus-code/issues/1264)):
the verification doctrine here is dense and unusually sophisticated,
and it was written **only** in places you find *after* you have made
the mistake — the leading comment blocks of test files, `CHANGELOG.md`
entries, and the closing paragraphs of `CLAUDE.md` trap bullets. Of 59
recent defects sampled at `dev` @ `989b8880`, **3 (5.1%) would have
been prevented by a stated guideline in force when the defective code
was written, and 43 (72.9%) were addressed by nothing**.

!!! note "This is doctrine, not machinery"

    Nothing on this page is enforced by a check. It is the statement of
    what the checks are *for*. The enforcement is indexed at the bottom;
    when a rule here acquires a guard, say so here and link it.

## The dominant class, in one definition

> **A check asserts a PROXY for the property it claims, and fails
> toward a well-formed answer at rc 0.**

The proxy is one of four things, and naming which one is how you find
the bug:

| the proxy is a wrong… | the check reads | the failure looks like |
|---|---|---|
| **predicate** | a different question, truthfully answered | a confident, plausible verdict |
| **population** | a set other than the one the claim is about | a confident *zero* or *few* |
| **status** | the rc of a later command, not the one that mattered | a manufactured success |
| **key** | a field that correlates with identity but is not it | a total that reconciles because its errors cancel |

**This class has a name in the literature, and the repo does not use
it.** It is a **"silent horror"** — Vahabzadeh, Milani Fard & Mesbah,
*"An Empirical Study of Bugs in Test Code"*, ICSME 2015: a test that
fails to detect a defect while reporting success. The mechanism is
**surrogation** — a measure standing in for a construct until the
measure *becomes* the construct in the author's reasoning. It is
**not** Goodhart's law: nobody is gaming the metric. There is no
adversary, no incentive, and no optimisation pressure. A careful
author picked a reasonable proxy, and the proxy and the property
coincided on every input anyone had.

That last sentence is why the class survives review. **Every existing
call site is correct, every test passes, and the trap is armed only
for code not yet written.** "It would pass review" is not a lapse
here; it is the predicted outcome.

### Recognising it in your own work

Three questions, in order. All three are static reads — no fixture, no
run.

1. **What is the property, and what did I actually measure?** Write
   both sentences down. If they are the same sentence, you have not
   separated them yet.
2. **Which direction does my measurement err in?** If you cannot say,
   you do not know whether your zero means *none* or *none that my
   rule can see*.
3. **Could an input match my SAFE arm and also a later DENY arm?** A
   classifier can be an allowlist, have a provably-reached
   default-deny, and still pronounce the single most direct expression
   of its hazard safe — because a permissive arm returned one arm too
   early
   ([`#1121`](https://github.com/<your-org>/nexus-code/issues/1121)).

### Three instances, because the shape is easier to recognise than the definition

- **A count that reconciles because its errors cancel is not
  verified.** A "PRs merged" denominator built from merge-commit
  subjects agreed with the true total *and had different membership*,
  by one member each way
  ([`#931`](https://github.com/<your-org>/nexus-code/issues/931),
  `#946`). The agreement is what stopped anyone looking.
- **A per-item probe that returns the same value for every item
  answered a question about their CONTAINER.** Nine analysis trees
  reported one identical sha, because `git -C <non-repo> rev-parse`
  walks up and answers about the enclosing repository at rc 0
  ([`#1196`](https://github.com/<your-org>/nexus-code/issues/1196)).
  Nothing errored; the *shape* of the answer was the only tell.
- **The property was bounded size; the rule was written about a
  proxy.** `docs/ng-interface-proposal.md` examined `monitor/ng` at
  **3,829 lines**, scored *"grows past 3829 lines"* as the explicit
  con of absorbing logic into it (`:173`), and then wrote its rule
  about a different thing entirely — *"reserve logic-in-`ng` for
  net-new ops with no standalone unit"* (`:181`). Every one of the
  largest in-`ng` verbs has no standalone unit, so **every increment
  was individually compliant**. Measured at `5bd6d400`
  (`git show 5bd6d400:monitor/ng | wc -l`): **13,326 lines** — 3.5x
  the size the ADR was written to bound. (Both quotes are cited by
  their CONTENT rather than by line alone; the ADR's blob at
  `5bd6d400` is `78ff7a6315af35a553966a6b8547230a4dce9b50`.) The dominant
  defect class, occurring inside this repo's own design governance.

## The rules

### G1 — Writing a rule obliges you to sweep the corpus that violates it

**This is the binding constraint, not the content of any rule below.**

> **A rule lands with its sweep, or it lands as a rule that the repo
> already violates.**

Measured: commit `c386bff` added the `PATHSPEC-GLOB-DEPTH` rule to
`CLAUDE.md` **and** the test that executes it **and** left the exact
documented violation sitting in the repo's own pre-push gate, green,
for fourteen more days.
[`#1056`](https://github.com/<your-org>/nexus-code/issues/1056) is the
same shape against `PIPELINE-STATUS`;
[`#1077`](https://github.com/<your-org>/nexus-code/issues/1077) sat 29
days over a violation that destroys the enclosing checkout.

So a PR that states a new rule **MUST** carry, in its body, one of:

- the sweep — the enumeration of existing violations, with its
  command and ref, and either their fixes or a named tracking issue;
- an explicit "swept, zero violators", with the command that found
  zero **and** a positive control proving that command can see one;
- an explicit statement that the rule is forward-only and why.

A rule with none of the three is a rule the repo is already breaking,
and nobody will find out from the rule.

### G2 — Any enumeration feeding a decision MUST be a set-equality against a generator

> **Every mechanism here verifies MEMBERS; almost none verifies
> MEMBERSHIP.**

An enumeration that is merely illustrative cannot be wrong, so nothing
signals when it stops being complete. The same gap has been found
independently at least four times: `CLAUDE.md` marker blocks with no
owning suite; `guards-for-diff`, where the great majority of suites
declare no population at all and are therefore *invisible to the index
rather than excluded by it*; the hand-enumerated pane-state list that
retires live workers; and `docs/reference/skills.md`, which catalogued
16 entries against 19 shipped skill directories, asserted by nothing.

So: **derive the list from a generator, assert set equality in BOTH
directions, and run a positive control before believing any absence.**
A one-directional check ("every row exists") passes on a list missing
half its members.

Do not derive membership from a name heuristic. A name-derived default
with an exception list is the `#1121` shape — a SAFE arm before a DENY
arm, decided by a string — and it was measured at an **18% miss rate**
on the `CLAUDE.md` marker corpus. Enumerate all rows explicitly.

### G3 — Every new guard MUST ship with a positive control it demonstrably catches

> **A guard that has never been seen to fail is a guard whose green
> means nothing.**

Plant a violation, prove the guard goes red on it, restore, prove it
goes green. Then keep the plant, so the guard goes red if the plant
stops being caught. This is Semgrep's `# ruleid:` discipline and
ESLint's `RuleTester` discipline, and it is the check that **would
have caught the `_tmux_shim_scan.awk` arm-ordering bug that three
skeptic rounds missed** — because every one of those rounds asked the
coverage question ("what spelling did you miss?") and the defect was
in arm *order*.

Two failure modes a naive positive control does not cover, both
measured:

- **The plant landed in the FILE and not in the RUN.** Prove both —
  md5 for the bytes, a structural grep for the construct, and an
  in-the-run probe for execution.
- **The guard went red on the wrong assertion.** Record *which*
  assertion fired and what it says. See [Tests](tests.md), *"Red is
  not enough"* under Conventions.

### G4 — Prefer a metamorphic relation where you have no oracle

For the *instrument-disagreement* family — where the bug is that your
tool answers a different question from the one you asked — you do not
need a fixture or advance knowledge of the failure mode. You need two
independent instruments that must agree.

Re-measured at `5bd6d400` with a clean index (nothing staged), because
these numbers are properties of a tree and the ones in `#1264` were
taken fourteen merges earlier:

```bash
# git's pathspec `*` crosses `/`; the shell's does not. They MUST agree.
git ls-files -- ':(glob)monitor/*.sh' | wc -l          # 118
#   vs the shell's tracked depth-1 expansion of monitor/*.sh   # 118  AGREE
#   the buggy form: git ls-files -- 'monitor/*.sh'             # 574

# ls-tree pathspecs are PREFIXES; ls-files pathspecs are GLOBS.
git ls-tree -r --name-only HEAD | grep -c '\.sh$'      # 576
git ls-files -- '*.sh' | wc -l                         # 576  AGREE
#   the buggy form: git ls-tree -r --name-only HEAD -- '*.sh'  # 0
```

A third pair, documented but **not re-measured here** because its
corpus (`reports/`) is operator-local rather than in this repo: an
ignore-file-blind search against `monitor/ng report-grep` over the
report corpus. Stated as a relation to use, not as a measurement.

When two such instruments disagree, one of them is answering about a
different population — and you have found the defect without ever
having known what to look for. Note that each buggy form above is a
**confident answer at rc 0**, one absurdly high and one absurdly low;
neither errors, and only the disagreement is visible.

### G5 — State a coverage boundary rather than a complete-looking list

An honest *"these rows are unmeasured, and here is why"* is worth more
than a list that reads as exhaustive and is not. This applies to test
skips (a skip that names what went unmeasured is honest; a red
everybody learns to ignore is not), to enumerations, and to this page.

### G6 — A count, a line number, and a red are properties of a TREE and a MOMENT

Carry the command, the ref, and — for anything a population guard
reads — whether the files were **staged**. A number nobody can re-run
is the same liability as a silent zero. The full statement of this
rule, with the measured traps, is the "count is a property of a tree"
family in `CLAUDE.md`; it is not restated here, because a second copy
is a second thing to keep true.

## Where the enforcement actually lives

The doctrine is executable, and this is the index it did not have. The
canonical source in each row is the file, not this table.

| Surface | What it holds | Where |
|---|---|---|
| **`CLAUDE.md` "Common gotchas"** | The trap catalogue: one entry per *tool that lies to you*, each with a fenced block that a suite EXECUTES. A `BEGIN`/`END` marker in that file is a promise that a suite runs the block. | repo root |
| **`monitor/watcher/test-claude-md-*.sh`** | The suites that execute those blocks against planted fixtures — so the gotcha list is checked, not asserted. | `monitor/watcher/` |
| **Test-file leading comments** | The single largest body of doctrine in the repo, and the reason this page exists: it is written where you find it after the fact. Individual suites' headers carry the mechanism, the incident, and the evidence standard. | `monitor/watcher/test-*.sh` |
| **`monitor/watcher/*.manifest`** | Rules recorded as **data** rather than prose, "because prose cannot be made to fail" — guard populations, nullglob bare forms, early-exit readers, known-red tolerations, and marker ownership. Each is ratcheted by a suite. | `monitor/watcher/` |
| **`ng guards-for-diff`** | Which registered guards READ your changed files — the gap between "I ran the suites near my edit" and `git push`. Read its blind-spot count, not its exit code: **0 is not a clearance**. | `monitor/guards-for-diff.sh` |
| **[Tests](tests.md) § Conventions** | Test-authoring doctrine in normative form: construct-vs-observe, red-by-construction, annotate-what-breaks, and the three structural blindnesses from [`#1210`](https://github.com/<your-org>/nexus-code/issues/1210). | this site |
| **[Development](development.md)** | The architectural invariants (no service, no daemon, no embedded DB) and the watcher-isolation rule. | this site |

Measured at `5bd6d400`, so you can calibrate how much of the corpus
the machine-checked layer covers:

```bash
# BEGIN/END marker blocks in CLAUDE.md that a suite promises to execute.
# This count is no longer only a claim: claude-md-markers.manifest names an
# owner for every one of them, and test-claude-md-marker-ownership.sh asserts
# the two sets are EQUAL in both directions.
git show 5bd6d400:CLAUDE.md | grep -cE '^ *<!-- BEGIN [A-Z0-9-]+ -->'          # 24

# suites that declare a population to guards-for-diff
git show 5bd6d400:monitor/watcher/guard-populations.manifest \
  | grep -cvE '^\s*(#|$)'                                                      # 27

# suites CI discovers in the fast band (monitor/ and monitor/watcher/, depth 1)
git ls-tree -r --name-only 5bd6d400 | grep -cE '^monitor/(watcher/)?test-[^/]*\.sh$'   # 384
```

**27 of 384 is the honest coverage boundary of the reverse index**, and
the reason its exit 0 must be read as "some declaring guard read a file
you changed", never as "the guard that matters ran".

Re-derived with the same three commands at `a3177ef6`: **27** marker
blocks, **75** suites declaring a population, **452** fast-band suites.
The ratio has improved (27/384 → 75/452) and the conclusion has not:
the great majority of suites are still invisible to the index rather
than excluded by it.

## What NOT to do

Measured and negative, so nobody re-derives them:

- **Do not split `monitor/ng`.** 2.25 fixes/KLOC against the watcher
  core's 8.54; 4 true collisions in 613 merges; zero live contention.
- **Do not restructure directories.** Co-change is 68%
  cross-directory and **benign**, corroborated independently by
  trial-merging 84 PR pairs.
- **Do not rewrite `CLAUDE.md` into a principles document.** A
  factorial study (1,650 sessions, 16,050 observations) found file
  size, position, architecture and internal contradictions produce
  **no detectable effect** on adherence.
- **Do not adopt ADRs wholesale.** No measured effect on drift; the
  modal outcome is "tried it, stopped". The one ADR this repo has is
  the third worked example under "Three instances" above.
- **Do not pitch ShellCheck as a doctrine lever.** Measured: roughly 2
  of roughly 25 `CLAUDE.md` entries subsumed, and `SC2006` fires on the backtick
  entry *with a remedy that does not fix the defect*. The blocker is
  that these failures live in ad-hoc command lines, which no file
  linter can see.

## Coverage boundary of this page

- The 59-defect sample, the 5.1% / 72.9% split, the `c386bff`
  fourteen-day window, the `#1121` 18% miss rate and the four "what
  not to do" studies are **`#1264`'s measurements at `dev` @
  `989b8880`**, not re-derived here. Every number carrying an explicit
  `5bd6d400` — including both figures in the ADR example, whose quoted
  strings were also checked against the file — was re-derived at that
  ref while this page was written.
- **Nothing on this page is machine-checked.** G2 is the rule this
  page itself is most exposed to: the enforcement index above is a
  hand-maintained enumeration with no generator, so treat it as a
  starting point and grep for what it missed.
- G1's sweep obligation has no guard for the corpus at large. Its
  `CLAUDE.md` half is now built: `monitor/watcher/claude-md-markers.manifest`
  declares an owner for every marker block — **27** rows against
  `CLAUDE.md`'s 27 markers at `a3177ef6`. (The manifest did not exist at
  `5bd6d400`; it arrived at `9451e842` with 24 rows, and its own header
  prose still says "all 24".) It is ratcheted by
  `monitor/watcher/test-claude-md-marker-ownership.sh` —
  set equality both directions against a generated marker set, so a
  marker added without an owner and an owner row left behind by a
  deleted marker are each RED. Ownership is DECLARED, never derived
  from the marker NAME: measured while building it, the narrow
  name-derived predicate reads 4 of 24 as unowned while three of them
  are executed, and the broad one over-finds (`DASH-PATTERN-OPTION`
  matches 6 files) — G2's own failure, in both directions at once.
  What remains unguarded is the rest of G1: writing a rule still
  triggers no sweep of the corpus OUTSIDE `CLAUDE.md`.
