#!/usr/bin/env python3
"""Reject a line number that does not pin its tree.

    monitor/lint-citations.py [--loose] FILE...   # exit 1 on any violation
    monitor/lint-citations.py --selftest          # plant defects, watch it fail

Why
---
`your-org/your-nexus#263` pinned a 40-hex SHA for its *code* permalinks, then
quoted manuscript line numbers read out of a *different tree* -- a working clone
parked on a side branch. A SHA sitting beside a bare `Lnnn` is **two references,
and only one of them is pinned**. Two published citations landed on unrelated
content; on `main`, one landed on a red reviewer note.

That is not a slip, it is a generator: nothing forces a line number to name the
tree it belongs to. This lint is the generator fix.

The rule
--------
    A line number without a tree is not a reference.

Every `Lnnn` (or `Lnnn-Lmmm`) must sit inside a commit-pinned permalink:

    [`file.py#L42-L80`](https://github.com/o/r/blob/<40-hex-sha>/path/file.py#L42-L80)

Violations:
  * a bare `L121` in prose
  * `file.tex:121` -- names a file, names no tree
  * `/blob/main/file.py#L5` -- looks pinned, is not; branches move

Modes
-----
strict (default) -- every `Lnnn` must be inside a SHA-pinned permalink.
--loose          -- a bare `Lnnn` is tolerated when the *same sentence* names a
                    tree (`main@e9a5c5a`, or a bare 7-40 hex SHA). Sentence-scoped
                    on purpose: in the founding defect the SHA sat one sentence
                    away from the line number, so --loose still catches it.

Both modes are stated here, in the open. Neither is a silent allowlist: an
exemption belongs in the fix, argued, never compiled into the checker.
"""
import re
import sys

LNUM = re.compile(r"(?<![A-Za-z0-9_])L\d+(?:-L\d+)?(?![A-Za-z0-9_])")
FENCE = re.compile(r"```.*?```", re.S)
MDLINK = re.compile(r"\[((?:[^\[\]]|\[[^\]]*\])*)\]\(([^)\s]+)\)")
PINNED = re.compile(r"/blob/[0-9a-f]{40}/[^#\s]+#L\d+(?:-L\d+)?$")
COLON = re.compile(r"[\w./-]+\.(?:py|tex|sh|R|md|json|ya?ml):\d+")
TREE = re.compile(r"(?:[\w./-]+@)?\b[0-9a-f]{7,40}\b")


def _fence_spans(s):
    """``` fenced blocks are transcripts, not citations.

    A console transcript that *demonstrates* the defect necessarily contains a bare
    `Lnnn` -- this lint's own repro does.  A line number inside a fence is not a
    clickable reference and cannot rot; it is quoted evidence.  Stated here in the
    open, and covered by a plant in both directions (see PLANTS): a bare `Lnnn` in
    prose is caught; the same string inside a fence is not.
    """
    return [m.span() for m in FENCE.finditer(s)]


def _pinned_spans(s):
    return [m.span() for m in MDLINK.finditer(s) if PINNED.search(m.group(2))]


def _bloblink_spans(s):
    return [m.span() for m in MDLINK.finditer(s)
            if "/blob/" in m.group(2) and "#L" in m.group(2)]


def _sentence_around(s, i):
    a = max(s.rfind(". ", 0, i), s.rfind("\n", 0, i)) + 1
    b = s.find(". ", i)
    return s[a:(b if b != -1 else min(len(s), i + 200))]


def violations(s, require_pin=True):
    ok = _pinned_spans(s)
    blob = _bloblink_spans(s)
    fence = _fence_spans(s)
    inside = lambda i: any(a <= i < b for a, b in ok)          # noqa: E731
    in_blob = lambda i: any(a <= i < b for a, b in blob)       # noqa: E731
    in_fence = lambda i: any(a <= i < b for a, b in fence)     # noqa: E731
    v = []
    for m in LNUM.finditer(s):
        if inside(m.start()) or in_blob(m.start()) or in_fence(m.start()):
            continue                       # pinned, or reported as unpinned-permalink
        if not require_pin and TREE.search(_sentence_around(s, m.start())):
            continue                       # loose rule, stated in the docstring
        v.append(("bare-line-number", m.group(0)))
    for m in COLON.finditer(s):
        if inside(m.start()) or in_fence(m.start()):
            continue
        v.append(("file:line-no-tree", m.group(0)))
    for m in MDLINK.finditer(s):
        t = m.group(2)
        if "/blob/" in t and "#L" in t and not PINNED.search(t):
            v.append(("unpinned-permalink", t[:70]))
    return v


SHA = "a" * 40
PLANTS = [
    ("plant: bare Lnnn in prose", "The claim sits at L121 of the manuscript.", True, 1),
    ("plant: file.ext:line", "See kompot_manuscript.tex:121 for the claim.", True, 1),
    ("plant: branch-pinned permalink",
     "See [`p.py#L5`](https://github.com/o/r/blob/main/p.py#L5).", True, 1),
    ("plant: founding defect (SHA one sentence away)",
     "Code pinned at e9a5c5a. The manuscript asserts the claim at L121.", False, 1),
    ("control: SHA-pinned permalink",
     "See [`panel.py#L42-L80`](https://github.com/o/r/blob/%s/notebooks/panel.py#L42-L80)." % SHA, True, 0),
    ("control: loose, sentence names the tree",
     "On main@e9a5c5a, L403 is a subsection heading.", False, 0),
    ("plant: bare Lnnn in prose, fence nearby",
     "```console\n$ lint file.md\n```\nThe claim sits at L121.", True, 1),
    ("control: bare Lnnn inside a fenced transcript",
     "```console\n$ printf 'the claim at L121' > /tmp/plant.md\n$ lint /tmp/plant.md\n"
     "  [bare-line-number] L121\n```", True, 0),
]


def _selftest():
    bad = 0
    for name, text, strict, expect in PLANTS:
        got = len(violations(text, require_pin=strict))
        ok = got == expect
        bad += (not ok)
        print("  %-46s expected=%d got=%d  %s"
              % (name, expect, got, "OK" if ok else "LINT IS BROKEN"))
    print("\nselftest: %s" % ("PASS -- the lint fails on every planted defect, "
                              "and passes both controls" if not bad else "FAIL"))
    return 1 if bad else 0


def main(argv):
    if "--selftest" in argv:
        return _selftest()
    loose = "--loose" in argv
    files = [a for a in argv if not a.startswith("--")]
    if not files:
        print(__doc__.strip().splitlines()[0])
        print("usage: lint-citations.py [--loose] FILE...  |  --selftest")
        return 2
    total = 0
    for p in files:
        with open(p) as fh:
            v = violations(fh.read(), require_pin=not loose)
        total += len(v)
        print("  %-30s violations=%d" % (p, len(v)))
        for kind, tok in v[:8]:
            print("      [%s] %s" % (kind, tok))
        if len(v) > 8:
            print("      ... and %d more" % (len(v) - 8))
    print("\nTOTAL: %d" % total)
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
