# Nexus glossary — approved definitions

One approved definition per internal term. Copy the definition
verbatim when you first use the term in an artefact. Do not write
a local variant.

This file exists because rule 6 of `nexus.writing` asks for
definitions that stay consistent across turns. An agent cannot
remember what the last session wrote. A tracked file can.

## How to use it

| Situation | Action |
|---|---|
| You use a listed term | Copy its definition into your first-use sentence. |
| Your term is missing | Add a row in the same PR that first uses the term. |
| A definition reads wrong | Fix it here. Do not work around it locally. |

Definitions are one clause. They must fit inside a sentence
after an em dash or inside parentheses. Keep them under 20 words.

## Nexus terms

| Term | Approved definition |
|---|---|
| nexus | a coordination repo that hosts project checkouts and turns GitHub issues into a control surface |
| orchestrator | the long-running agent that reads the watcher and dispatches work to workers |
| watcher | the headless poller that snapshots GitHub and the workspace, then prints findings for the orchestrator |
| worker | an agent spawned into its own tmux window to do one delegated task |
| emit | one block the watcher prints for the orchestrator to act on |
| eligible comment | a GitHub comment the watcher judges as new work for the orchestrator |
| floor | the `## Worker floor` section injected verbatim into every worker spawn prompt |
| spawn | to launch a worker in a new tmux window via `monitor/spawn-worker.sh` |
| resume | to relaunch a worker into its own window, so it continues the same task |
| lifecycle anchor | the `spawn` action-log event that marks when a window's current life began |
| wrap-up | the hand-off step that checks a report, uploads it, and comments the link on the issue |
| re-wrap-up | a second wrap-up that the same worker runs on the same result |
| report | the file under `reports/` an agent writes before finishing, so the work can resume without the session |
| skeptic | an independent agent that adversarially rechecks another worker's result |
| skeptic round | one validation pass, from the request that opens it to the verdict that closes it |
| verdict | the skeptic's ruling on a worker's result, which closes the skeptic round |
| pending marker | the file `monitor/.state/skeptic/pending/<window>`, which marks a worker as awaiting a skeptic |
| head | the tip commit of a pull request's branch |
| validated head | the exact commit a verdict states it covers, which the verdict does not extend past |
| verdict trailer | the `Skeptic-Verdict:` line in a pull-request body that names the verdict and its validated head |
| parked | idle on purpose and exempt from window cleanup, usually while waiting for a skeptic |
| ghost | Claude Code's dim autosuggest text in a pane, which looks like typed input but is not |
| preflight | a check that runs before an action and blocks it when a condition fails |
| unstick | the watcher's routine that clears a blocked agent pane, by answering a dialog or re-submitting |
| rocket | the reaction added to a comment to mark it fully processed, by the bot or by the operator |
| dashboard | the structured body of the overview issue that reports current nexus state |
| overview issue | the routing-only issue tagged `nexus:overview`, normally issue 1 |
| secondary clone | a clone or worktree a worker edits freely, landing canonical changes by PR or via the primary clone |
| bot | the GitHub App identity that makes every write, so the operator gets notified |
| over-limit hold | the watcher state that suppresses routine emits to a window it believes is rate limited |
| scan window | the last 15 non-blank pane rows above the input box, the only rows the over-limit detector reads |
| hook stamp | the JSON file a Claude Code hook writes when a turn fails on a rate limit, naming the window and its reset |
| reset_at token | the single-token reset time the detector extracts from a limit notice, for example `3am_America/Los_Angeles` |
| provenance filter | the step that drops scan-window rows that are quoted source text rather than a painted notice |
| fixture | a recorded pane capture that a test replays in place of a live tmux pane |
| tracked fixture | a fixture committed to the repository, so its absence is a broken checkout and never a normal condition |
| silent skip | a test the harness does not run, does not count, and does not report, so the suite still reads green |
| mutation arm | one deliberate break of the code under test, run to prove that a stated assertion turns the suite red |
| landed-mutation proof | a checksum and a diff taken after a mutation and before the suite runs, so a green arm cannot be a mutation that never applied |
| dangling symlink | a symbolic link whose target does not exist |
| negative control | a mutation arm that must turn the suite red, so a green result marks a hole in the suite |
| masked assertion | an assertion that passes against broken code, because a different check rejects its input first |
| per-assertion attribution | the rule that a mutation arm counts as caught only when the assertion it targets turns red |
| hermetic suite | a suite that writes only inside its own sandbox, so no run can change the result of a later run |
| collision surface | one nexus file or contract that a Claude Code release can break, listed in `skills/nexus.cc-update/GUIDE.md` |
| cc-harness gate | `monitor/cc-harness/gate.sh`, which drives a candidate Claude Code binary and asserts the pane classifier still works |
| local pin | `monitor/.state/cc-version-local`, the gitignored file that sets the Claude Code version this operator runs |
| version floor | the `package.json` Claude Code version, used only for a fresh install that has no local pin |
| bracketed paste | a paste that tmux wraps in the terminal's paste markers (`paste-buffer -p`), so the receiving program reads the text as one literal block |
| watch item | a release change that does not block a version bump, but that an operator must check if the behaviour it names misbehaves later |
| barrier assertion | a negative assertion made only after an event that must order after the thing asserted absent, so no timer decides the verdict |

## Project terms

Add domain terms here when they recur across reports. A term used
once in one report does not belong in this file; define it inline
and move on.

| Term | Approved definition |
|---|---|
| _(none yet)_ | |
