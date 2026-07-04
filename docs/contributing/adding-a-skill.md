# Adding a skill

A *skill* is a Markdown file under `skills/nexus.*/SKILL.md` that
Claude Code discovers at runtime and surfaces to the agent when
its frontmatter description matches the task at hand. Skills are
how the nexus extends the agent's behaviour without bloating
`CLAUDE.md`: a skill loads only when it's relevant, leaving the
default context lean.

See the [Skills catalog](../reference/skills.md) for the fourteen
skills that ship today.

## When to add a skill vs editing prose

A new skill earns its place when **all** of these are true:

- The behaviour is invoked from many task shapes, not one
  specific PR or worker prompt.
- The trigger is sharper than "always" — there's a clear
  condition under which the rule fires (and many cases where
  it doesn't, so the agent shouldn't carry it by default).
- The body is too detailed to inline into `CLAUDE.md` or a
  spawn prompt without bloating the always-loaded context
  past usefulness.

If two of those are true, add to `CLAUDE.md` or the relevant
existing skill instead. Skills are a soft surface — Claude Code's
discovery scans frontmatter on every turn, and a skill that
never quite triggers is invisible scaffolding.

Counter-cases that look like skills but aren't:

- **The "every worker should do X" rule** belongs in
  `skills/nexus.worker-defaults/SKILL.md`'s `## Worker floor`
  section, which `monitor/spawn-worker.sh` injects verbatim
  into every worker prompt. Don't author a new skill for this;
  workers can't discover skills reliably from cwds under
  `work/<project>/` anyway. Edit the floor.
- **A workflow-internal recipe** (e.g. "how to back-fill the
  dashboard from action-log") belongs in the relevant skill's
  body or in the operator docs. Don't fragment it out.
- **A bug-fix or one-off pattern** belongs in the report that
  documents the fix, not in a skill.

## Anatomy of a skill

Every skill is a single file: `skills/nexus.<slug>/SKILL.md`.
The directory exists so that skill-local fixtures or attached
files can live alongside the body if needed; most skills today
are just the `SKILL.md`.

The file has three mandatory parts.

### 1. Frontmatter

```markdown
---
description: "One-sentence summary that the discovery scan reads. Be specific. The agent decides whether to load the skill from this line alone."
---
```

Conventions from the existing skills:

- Single line, double-quoted, no line break. The discovery
  parser is forgiving but every shipping skill keeps it tight.
- Lead with the *behaviour*, not the *audience*. "Spawn
  delegated nexus work in tmux windows" beats "How agents
  should delegate work".
- Mention the load-bearing identifier so a keyword search hits.
  `nexus.bot`'s description names `monitor/ng` and `mint-token.sh`;
  `nexus.report` names `reports/{project}_{ts}_{slug}.md`.
- ≤ 200 characters. The whole point is that the agent reads
  many of these to decide which skill to load.

### 2. H1 + TRIGGER paragraph

```markdown
# nexus.<slug> — <one-line title>

TRIGGER when: <condition>; <condition>; <condition>.
```

The H1 names the skill (matching the directory) and gives a
one-line subtitle. The `TRIGGER when: ...` paragraph
immediately below is the human-readable version of the
frontmatter description — it lists every condition under which
the skill should fire, separated by semicolons. Claude Code's
discovery does fuzzy matching, but a thorough TRIGGER line is
the discoverability backstop.

Counter-example: `nexus.worker-defaults` doesn't have a
`TRIGGER when:` line because its `## Worker floor` section is
*injected* into every worker by `monitor/spawn-worker.sh` — the
discovery surface doesn't apply. If your skill is injection-only
and never agent-discovered, you can drop the TRIGGER line, but
keep the frontmatter description for the catalog.

### 3. Body sections

The body convention varies — see the existing skills as
templates. A common shape:

```markdown
## The one rule
<single load-bearing sentence>

## Why
<motivation>

## <Operational section(s)>
<step-by-step / verb table / decision tree>

## See Also
<cross-links to other skills / CLAUDE.md anchors>
```

H2 boundaries matter for `nexus.worker-defaults` (its
`## Worker floor` section is awk-extracted by
`monitor/spawn-worker.sh`); they don't carry the same
load-bearing weight elsewhere, but the convention helps
readers skim.

## Audience: who consumes the skill

Every skill is for one of three audiences. Be explicit at the
top of the body — readers should know within a glance whether
they're meant to act on this skill or just read it.

- **Orchestrator-only.** `nexus.window-cleanup`,
  `nexus.infra-review`, `nexus.tmux-spawn`. These describe
  things the orchestrator does on behalf of the system; a
  worker never invokes them.
- **Worker-readable.** `nexus.bot`, `nexus.report`. Workers
  consult these when their delegated task needs a verb table or
  a section-format reminder. The orchestrator reads them too.
- **Injection-only.** `nexus.worker-defaults`. The body is
  embedded into worker prompts at spawn time and never
  discovered through the live skill scan.

State the audience in the body — `nexus.worker-defaults`'s
opening sentence is the canonical example: "This skill's
`## Worker floor` section is injected verbatim by
`monitor/spawn-worker.sh` into every spawn prompt. Don't
reference this skill from inside a worker prompt."

## Discoverability

Claude Code discovers skills by scanning `~/.claude/skills/` for
files matching `*.md` (subdirectories included) and reading
their frontmatter `description`. The discovery is best-effort:

- The `.claude/skills` symlink in this repo points at the
  workspace `skills/` directory so a Claude Code session
  launched from anywhere under the nexus root finds the
  skills. If your fork or fresh clone is missing the symlink,
  agents will silently fail to discover the skill — check
  `ls -la .claude/skills` first.
- Skills under `skills/` may not auto-discover when the
  agent's cwd is inside `work/<project>/...`. That's why
  `CLAUDE.md` lists every skill by absolute path in its
  "Skills" table and worker prompts reference skills by
  absolute path. When you ship a new skill, add the same row
  to that table so reflexive consultation works for any cwd.
- A skill with a vague description, or one whose body never
  uses the keywords its description promises, won't surface
  reliably. Test by running the agent through a representative
  task and confirming the skill loads.

## End-to-end checklist

1. **Pick the slug.** `nexus.<concept>`; short, kebab-case,
   nameable.
2. **Create the directory** and write `SKILL.md` with
   frontmatter + H1 + `TRIGGER when:` line + the body
   sections you need.
3. **State the audience** in the first paragraph of the body
   (orchestrator / worker / injection-only).
4. **Link from `CLAUDE.md`'s Skills table.** Add a row with
   the "use when" framing. The orchestrator re-anchors from
   this table; an unlisted skill is invisible to the
   orchestrator's check-on-uncertainty habit.
5. **Cross-link from related skills** under their `## See
   Also` blocks so a reader who lands on a sibling can find
   the new one.
6. **Update [`docs/reference/skills.md`](../reference/skills.md)**
   so the public catalog stays in sync.
7. **If the skill drives a runtime behaviour** (e.g. a verb
   the watcher invokes, a check the orchestrator runs), wire
   the test for that behaviour into the existing
   `monitor/watcher/test-*.sh` suite. See
   [Tests](tests.md) for the patterns.
8. **Land it in a PR.** Title prefix: `skills: add
   nexus.<slug>` for a new skill, `skills: <imperative>` for
   an edit. Body should name the trigger and the audience so
   the reviewer can sanity-check the discovery story.

The point of the skill system is the agent loads each one
*only when relevant*. Tightening the description + TRIGGER pair
is the single most useful editing pass you can make.
