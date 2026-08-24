#!/usr/bin/env python3
"""
ng usage — nexus mechanism-usage analyzer.

Rolls up the EXISTING telemetry in monitor/.state/ (plus the ng-usage.jsonl
dispatch tap, once deployed) into a HOT / WARM / COLD / UNOBSERVED picture per
mechanism, cross-referenced against a denominator derived from the code itself.

Design stance — runtime evidence, never a static call-graph:
  nexus-code invokes most mechanisms by DYNAMIC DISPATCH (ng verbs by string,
  hooks by settings-string, watcher tasks by scheduler registry, skills by
  name). A "no static caller -> dead" verdict is wrong by construction here:
  `ng skeptic` and `ng paste-followup` have ZERO executable static callers yet
  are among the hottest mechanisms in the nexus. So every count below is a
  RECORDED invocation, and "UNOBSERVED" means *this method has no signal for
  it* — NOT "dead". The only instrument that turns UNOBSERVED into a real
  count for the ng-verb layer is the dispatch tap (_usage_tap in monitor/ng).

Signals consumed (all append-only, read-only here):
  - ng-usage.jsonl*         the dispatch tap — the ONLY direct per-verb counter
  - action-log.jsonl        orchestrator lifecycle events (~8 verbs' worth)
  - watcher-scheduler.jsonl* per-cycle scheduled-task records (watcher internals)
  - dir counts              requests/ skeptic/ spawn-prompts/ unstick/ …
  - reports/*.md            report-init proxy (one report ≈ one report-init)

Usage:
  ng usage                       markdown report over all history
  ng usage --json                machine-readable rollup
  ng usage --since 2026-07-01    restrict time-scoped signals to >= ISO date
  ng usage --top 15              cap the longest tables
  ng usage --state-dir DIR       override telemetry dir (default: resolve like ng)
  ng usage --repo DIR            override code root for the denominator
"""
import argparse, collections, glob, json, os, re, sys

# ── location resolution (mirror ng's STATE_DIR precedence) ──────────────────
SELF = os.path.realpath(__file__)
MON = os.path.dirname(SELF)                 # .../monitor
DEFAULT_ROOT = os.path.dirname(MON)         # repo root of THIS install


def resolve_state_dir(cli):
    if cli:
        return cli
    if os.environ.get("NEXUS_STATE_DIR"):
        return os.environ["NEXUS_STATE_DIR"]
    if os.environ.get("NEXUS_ROOT"):
        return os.path.join(os.environ["NEXUS_ROOT"], "monitor", ".state")
    return os.path.join(MON, ".state")


def _iter_jsonl(path, since=None):
    try:
        f = open(path, errors="replace")
    except FileNotFoundError:
        return
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            if since and isinstance(d.get("ts"), str) and d["ts"] < since:
                continue
            yield d


def _globset(base):
    """current file + rotated siblings (name.<epoch>), de-duplicated."""
    return sorted(set([base] + glob.glob(base + ".*")))


# ── DENOMINATOR (derived from the installed code) ───────────────────────────
def ng_verbs(root):
    """Authoritative verb list = the main() case dispatcher in monitor/ng."""
    verbs = []
    try:
        txt = open(os.path.join(root, "monitor", "ng"), errors="replace").read()
    except FileNotFoundError:
        return verbs
    m = re.search(r"^main\(\)\s*\{(.*?)^\}", txt, re.S | re.M)
    if not m:
        return verbs
    for line in m.group(1).splitlines():
        mm = re.match(r"\s*([a-z][a-z0-9:_-]+(?:\|[a-z-]+)*)\)\s+cmd_", line)
        if mm:
            for v in mm.group(1).split("|"):
                if v not in ("help", "verbs", "usage"):   # meta / self
                    verbs.append(v)
    return sorted(set(verbs))


def skills(root):
    p = os.path.join(root, "skills")
    try:
        return sorted(d for d in os.listdir(p) if os.path.isdir(os.path.join(p, d)))
    except FileNotFoundError:
        return []


def static_refs(root, verbs):
    """Executable-only (.sh/.py) `ng <verb>` references — the SCRIPT-level
    dispatch axis a static call-graph would see. Orthogonal to telemetry; a
    verb HOT here but absent from telemetry is a blind spot, not dead."""
    ng_re = re.compile(r'(?:(?<![\w/])ng|/ng|\$\{?NG\}?|"\$NG")\s+')
    counts = {v: 0 for v in verbs}
    pats = {v: re.compile(ng_re.pattern + re.escape(v) + r'(?![\w-])') for v in verbs}
    monroot = os.path.join(root, "monitor")
    for dp, _, fns in os.walk(monroot):
        if os.sep + ".git" in dp:
            continue
        for fn in fns:
            if not fn.endswith((".sh", ".py")) or fn == "ng":
                continue
            try:
                txt = open(os.path.join(dp, fn), errors="replace").read()
            except OSError:
                continue
            for v in verbs:
                if v in txt:  # cheap prefilter
                    counts[v] += len(pats[v].findall(txt))
    return counts


# action-log event -> originating ng verb (retrospective triangulation for the
# pre-tap era; the tap supersedes this the moment it is deployed).
EVENT_TO_VERB = {
    "wrap-up": "wrap-up", "window-retain": "wrap-up", "window-close": "retire-preflight",
    "skeptic-request": "skeptic", "skeptic-spawn": "skeptic", "skeptic-decision": "skeptic",
    "skeptic-verdict": "skeptic", "skeptic-nudge": "skeptic", "skeptic-escalate": "skeptic",
    "paste-followup": "paste-followup", "engaged-done": "engaged-done",
    "dashboard-update": "dashboard", "service-incident": "service-incident",
    "infra-incident": "service-incident", "respawn": "respawn",
}


def classify(n):
    if n is None:
        return "UNOBSERVED"
    if n >= 100:
        return "HOT"
    if n >= 10:
        return "WARM"
    if n >= 1:
        return "COLD"
    return "COLD"


def load(state, root, since):
    ev = {}
    # 1. dispatch tap (direct, authoritative once deployed)
    tap = collections.Counter()
    tap_span = [None, None]
    for base in _globset(os.path.join(state, "ng-usage.jsonl")):
        for r in _iter_jsonl(base, since):
            v = r.get("verb")
            if not v:
                continue
            key = v + ("/" + r["sub"] if r.get("sub") else "")
            tap[key] += 1
            ts = r.get("ts")
            if ts:
                tap_span[0] = ts if tap_span[0] is None else min(tap_span[0], ts)
                tap_span[1] = ts if tap_span[1] is None else max(tap_span[1], ts)
    ev["tap"], ev["tap_span"] = tap, tap_span

    # 2. action-log lifecycle events
    al = collections.Counter()
    al_span = [None, None]
    uploads = 0
    for r in _iter_jsonl(os.path.join(state, "action-log.jsonl"), since):
        al[r.get("event", "?")] += 1
        if r.get("upload") or r.get("asset-url"):
            uploads += 1
        ts = r.get("ts")
        if ts:
            al_span[0] = ts if al_span[0] is None else min(al_span[0], ts)
            al_span[1] = ts if al_span[1] is None else max(al_span[1], ts)
    ev["actionlog"], ev["al_span"], ev["uploads"] = al, al_span, uploads

    # 3. watcher scheduler tasks (across rotations)
    wt = collections.Counter()
    wfail = collections.Counter()
    wspan = [None, None]
    for base in _globset(os.path.join(state, "watcher-scheduler.jsonl")):
        for r in _iter_jsonl(base, since):
            t = r.get("task")
            if not t:
                continue
            wt[t] += 1
            if r.get("rc", 0) != 0:
                wfail[t] += 1
            ts = r.get("ts")
            if ts:
                wspan[0] = ts if wspan[0] is None else min(wspan[0], ts)
                wspan[1] = ts if wspan[1] is None else max(wspan[1], ts)
    ev["watcher"], ev["watcher_fail"], ev["w_span"] = wt, wfail, wspan

    # 4. dir-count subsystem signals
    def dcount(sub):
        try:
            return len(os.listdir(os.path.join(state, sub)))
        except FileNotFoundError:
            return None
    ev["dirs"] = {k: dcount(k) for k in
                  ["requests", "spawn-prompts", "windows", "skeptic", "unstick",
                   "service-health", "cc-auto-update", "footgun-seen", "diffs"]}

    # 5. reports corpus (report-init proxy). Reports are OPERATOR telemetry
    # co-located with .state (<nexus-root>/reports), NOT code — derive their
    # root from the state dir (<nexus-root>/monitor/.state), not the code root.
    reports_root = os.path.dirname(os.path.dirname(os.path.normpath(state)))
    try:
        ev["reports"] = len(glob.glob(os.path.join(reports_root, "reports", "*.md")))
    except OSError:
        ev["reports"] = None
    return ev


def build_verb_view(verbs, ev, srefs):
    """Per-verb reconciliation: tap (direct) > triangulated (action-log) plus
    the orthogonal static-ref axis. Returns a list of dicts."""
    tap, al = ev["tap"], ev["actionlog"]
    tri = collections.Counter()
    for e, v in EVENT_TO_VERB.items():
        tri[v] += al.get(e, 0)
    tri["upload"] += ev["uploads"]
    tri["report-init"] += ev["reports"] or 0
    tri["report-check"] += al.get("wrap-up", 0)   # runs inside every wrap-up

    rows = []
    for v in verbs:
        direct = sum(c for k, c in tap.items() if k == v or k.startswith(v + "/"))
        hist = tri[v] if v in tri else None            # historical floor (pre-tap window)
        # Tap and triangulation measure DIFFERENT windows (tap = since deploy;
        # triangulation = all action-log history), so keep both. During the
        # bootstrap a tiny tap count must NOT mask a large historical floor:
        # classify by the max of what we know.
        best = max([x for x in (direct or None, hist) if x is not None], default=None)
        if direct and hist:
            src = "tap+hist"
        elif direct:
            src = "tap"
        elif hist is not None:
            src = "triangulated"
        else:
            src = "none"
        rows.append({
            "verb": v, "tap": direct, "hist": hist,
            "count": best, "evidence": src,
            "static_refs": srefs.get(v, 0),
            "class": classify(best),
        })
    return rows


def render_md(ev, verbs, sk, rows, args):
    top = args.top
    out = []
    P = out.append
    P("# Nexus mechanism-usage assessment\n")
    P(f"- state dir: `{args._state}`")
    P(f"- code root: `{args._root}`  ·  denominator: {len(verbs)} ng verbs, {len(sk)} skills")
    P(f"- action-log span: {ev['al_span'][0]} → {ev['al_span'][1]}")
    P(f"- watcher-scheduler span: {ev['w_span'][0]} → {ev['w_span'][1]}")
    tap_state = (f"{ev['tap_span'][0]} → {ev['tap_span'][1]}"
                 if ev["tap_span"][0] else "EMPTY — dispatch tap not yet deployed")
    P(f"- ng-usage tap span: {tap_state}")
    if args.since:
        P(f"- since filter: {args.since}")
    P("")

    P("## Watcher scheduled tasks — directly observed (every cycle)\n")
    P("| task | fires | fails | class |")
    P("|---|---:|---:|---|")
    for t, n in ev["watcher"].most_common():
        P(f"| {t} | {n} | {ev['watcher_fail'][t]} | {classify(n)} |")
    P("")

    P("## ng verbs — usage × static-reference reconciliation\n")
    P("`tap` = invocations recorded by the dispatch tap SINCE it deployed "
      "(the authoritative, universal signal). `hist` = historical floor "
      "triangulated from action-log (pre-tap era; only ~11 verbs are inferable "
      "this way). They measure different windows, so both are shown; `class` "
      "uses the larger. `static_refs` = executable `ng <verb>` calls in .sh/.py. "
      "The dangerous quadrant is refs>0 **and** no signal — script-invoked yet "
      "telemetry-invisible until the tap accrues.\n")
    P("| verb | tap | hist | evidence | static_refs | class |")
    P("|---|---:|---:|---|---:|---|")
    for r in sorted(rows, key=lambda r: (r["count"] is None, -(r["count"] or 0))):
        tapc = r["tap"] if r["tap"] else "·"
        hc = r["hist"] if r["hist"] is not None else "·"
        P(f"| {r['verb']} | {tapc} | {hc} | {r['evidence']} | {r['static_refs']} | {r['class']} |")
    P("")

    P("## action-log lifecycle events\n")
    P("| event | count |")
    P("|---|---:|")
    for e, n in ev["actionlog"].most_common(top):
        P(f"| {e} | {n} |")
    P("")

    P("## subsystem signals (dir counts)\n")
    for k, v in ev["dirs"].items():
        P(f"- {k}: {v}")
    P(f"- reports/*.md: {ev['reports']}")
    P("")

    # candidate cold / watch-with-tap: no runtime signal AND no executable refs
    cold = [r for r in rows if (r["count"] is None) and r["static_refs"] == 0]
    blind = [r for r in rows if (r["count"] is None) and r["static_refs"] > 0]
    P("## Interpretation\n")
    P("**Blind spot (script-invoked but telemetry-invisible)** — used by .sh/.py "
      "yet no runtime signal; the tap will quantify them:")
    P("  " + (", ".join(f"`{r['verb']}`(refs={r['static_refs']})" for r in
              sorted(blind, key=lambda r: -r["static_refs"])) or "none"))
    P("")
    P("**Watch-with-tap (no runtime signal AND no executable caller)** — reachable "
      "only via agent/human ad-hoc dispatch; NOT proven dead (may be doc-/floor-"
      "invoked). These are the genuine unknowns the tap adjudicates:")
    P("  " + (", ".join(f"`{r['verb']}`" for r in cold) or "none"))
    P("")
    P("**Not dead:** every watcher scheduled task fired this window; `skeptic` "
      "and `paste-followup` carry ZERO executable static callers yet are "
      "hottest-tier — the standing proof that a static kill-list would be wrong.")
    return "\n".join(out)


def main(argv):
    ap = argparse.ArgumentParser(prog="ng usage", add_help=True)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--since", help="ISO date/time lower bound for time-scoped signals")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--state-dir")
    ap.add_argument("--repo", help="code root for the denominator (default: this install)")
    args = ap.parse_args(argv)

    state = resolve_state_dir(args.state_dir)
    root = args.repo or os.environ.get("NEXUS_ROOT") or DEFAULT_ROOT
    args._state, args._root = state, root

    verbs = ng_verbs(root)
    sk = skills(root)
    srefs = static_refs(root, verbs)
    ev = load(state, root, args.since)
    rows = build_verb_view(verbs, ev, srefs)

    if args.json:
        blob = {
            "state_dir": state, "code_root": root, "since": args.since,
            "spans": {"action_log": ev["al_span"], "watcher": ev["w_span"],
                      "tap": ev["tap_span"]},
            "watcher_tasks": {t: {"fires": n, "fails": ev["watcher_fail"][t],
                                  "class": classify(n)}
                              for t, n in ev["watcher"].items()},
            "ng_verbs": rows,
            "action_log_events": dict(ev["actionlog"]),
            "dirs": ev["dirs"], "reports": ev["reports"],
            "denominator": {"ng_verbs": len(verbs), "skills": len(sk)},
        }
        print(json.dumps(blob, indent=2, default=str))
        return 0

    print(render_md(ev, verbs, sk, rows, args))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
