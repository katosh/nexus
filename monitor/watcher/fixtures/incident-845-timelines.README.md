# `incident-845-timelines.jsonl` — the recorded incidents, not a reconstruction

Transcribed VERBATIM from this operator's `monitor/.state/action-log.jsonl`
on 2026-08-14, filtered to the pairing-relevant event types
(`spawn`, `skeptic-spawn`, `skeptic-verdict`, `skeptic-request`,
`skeptic-decision`, `wrap-up`, `window-retain`, `window-close`) for the six
windows involved in the two `<your-org>/nexus-code#845` instances:

    tmuxwrap / sk897          the 2h 18m unrouted-head wait
    papercuts / sk900, sk911, sk911b   the retired-mid-obligation reviewer

## Why this file exists instead of a fixture

The first version of `test-obligations.sh` planted a hand-built fixture —
an edge, a live pending marker, an idle pane — and asserted that
`retire-preflight` refused. It passed. It was also **wrong**, and wrong in
the one way a test cannot catch by being more careful: the fixture encoded
the author's MODEL of the incident (an obligation outstanding at the moment
of retirement) rather than the incident's actual STATE.

The real `sk911` retirement happened **after** its first verdict, when both
release paths had already fired and the edge was closed. Replaying the
recorded timeline through the shipped code returns `safe=1`. The planted
fixture never reached that state, so it confirmed the model instead of
testing it.

    2026-08-14T08:58:04  skeptic-spawn   sk911 -> papercuts    (edge opens)
    2026-08-14T09:19:36  skeptic-verdict sk911 -> papercuts    (edge closed HERE)
    2026-08-14T09:21:21  window-retain   sk911                  <- hazard begins
    2026-08-14T10:41:37  skeptic-spawn   sk911b -> papercuts    (a THIRD reviewer
                                                                 had to be spawned)

`papercuts` is still being worked at 10:55 and 11:04. The gap
`[first verdict -> next re-arm]` is the whole hazard, and it is the interval
the planted fixture skipped over.

## The rule this encodes

**Replay the incident from recorded state; do not construct the state you
expect the incident to have had.** The action log is the recorded state, and
it is available for every incident this workspace has ever had.

## Maintenance

Append-only. Timestamps are the real ones and the replay is driven off their
ORDER, not their absolute values, so the fixture does not rot. Adding a new
incident means transcribing another slice — never editing an existing one,
because an edited timeline is a reconstruction again.
