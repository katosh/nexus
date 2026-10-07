#!/usr/bin/env python3
"""probe-2g-limits.py — re-read the plugin-monitor OUTPUT LIMITS from a claude
binary, by STRUCTURE rather than by minified name (your-org/nexus-code#1734).

skills/nexus.cc-update/GUIDE.md §2g ("The host's per-monitor OUTPUT LIMITS")
pins five constants the longjob dispatcher's pacing depends on (#1535): the
token bucket's capacity and refill period, the per-line cut, the per-batch cut
and the batch interval. The GUIDE used to say "re-read the constants from the
candidate's strings (`dce=`, `Ate=`, `bVe=`)". Those were ONE build's minified
identifiers; minified names move every build, they were already absent on
2.1.283, and following the instruction produced an EMPTY extraction that read
as "nothing to report" — a check that silently checked nothing.

This probe matches the SHAPE of the code instead, and confirms each constant
is the one actually USED, not merely a nearby declaration:

  1. the token-bucket module   var A=<cap>,B=<ms>;function F(m,n,t=Date.now){let e=m,o=t();
  2. its plugin-monitor wiring =F(A,B)){let z=0;function y(){if(z===0)return;
                               followed within 400 bytes by `[plugin monitor … suppressed`
  3. the batcher               function G(e,t=(n)=>{let o=setTimeout(n,J);return()=>clearTimeout(o)}){
     and its constants         var b=<line>,E=<batch>,J=<ms>,L=1048576;  (within 6 KB before G)
     each USED as a cut        `c.length>b` and `a.length>E` inside G's body
  4. the monitor arming        G(<x>.onBatch)

FAIL-CLOSED CONTRACT. Every step prints what it matched. A step that does not
match prints `UNRESOLVED: …`, and the probe exits 3 — it NEVER prints a guessed
or remembered value. A partial RESULT line at rc 3 carries only the values that
WERE verified, and reads `RESULT [label] UNRESOLVED … (INCOMPLETE)`; the caller
must record the 2g limits as UNVERIFIED, never as unchanged.

Usage: probe-2g-limits.py <claude-binary> <label>
  <claude-binary>  the native claude executable (NOT a node shim or symlink
                   to cli.js — resolve it first; a shim resolves to rc 3)
  <label>          free text echoed in the RESULT line (e.g. the version)

Exit codes:
  0  all five resolved and cross-checked
  2  usage error: wrong argument count, or the binary could not be READ
     (missing, a directory, permission denied) — no measurement was made
  3  UNRESOLVED: the file was read and at least one step did not match

Runs on python3 3.6 (this host's interpreter): no walrus, no fromisoformat.

Provenance: filed by another operator's cc-auto-update evaluator via
your-org/nexus-code#1734 (validated there on 2.1.283/.287/.288/.289, values
unchanged: bucket 10, refill 2000 ms, line cut 500, batch cut 3000, batch
interval 200 ms; controls /bin/ls → rc 3 and a doctored line-cut use → rc 3).
Shipped here with argument validation and a uniqueness check on the wiring.
"""
import re
import sys

USAGE = "usage: probe-2g-limits.py <claude-binary> <label>"

if len(sys.argv) != 3 or not sys.argv[1] or sys.argv[1] in ("-h", "--help"):
    print(USAGE, file=sys.stderr)
    sys.exit(2)

path, label = sys.argv[1], sys.argv[2]
try:
    # A plain read, not mmap: mmap of a ZERO-byte file raises ValueError, and an
    # empty file is a readable input that must come back UNRESOLVED (rc 3), not
    # a crash. The binary is ~200 MB; the issue's version copied the mmap into
    # bytes anyway (`mm[:]`), so the memory footprint is the same.
    with open(path, "rb") as fh:
        data = fh.read()
except OSError as exc:
    print("ERROR: cannot read {!r}: {}".format(path, exc), file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)

N = rb"[A-Za-z0-9_$]+"
out = {}
ok = True


def fail(msg):
    global ok
    ok = False
    print(f"  UNRESOLVED: {msg}")


# 1. token bucket + its plugin-monitor wiring
m = re.search(rb"var (" + N + rb")=([0-9]+),(" + N + rb")=([0-9]+);function (" + N
              + rb")\(m,n,t=Date\.now\)\{let e=m,o=t\(\);", data)
if not m:
    fail("token-bucket module (var A=<n>,B=<n>;function F(m,n,t=Date.now){let e=m,o=t();)")
else:
    capn, cap, refn, ref, fn = (x.decode() for x in m.groups())
    print(f"  bucket module @{m.start()}: var {capn}={cap},{refn}={ref}; function {fn}(capacity,refill_ms)")
    # Every call site of F with this shape, then ONLY those that feed the
    # plugin-monitor suppressor. The issue's version took the FIRST call site
    # and failed if it was not the monitor's; a second F consumer earlier in the
    # bundle would then read UNRESOLVED for no reason. Two monitor wirings that
    # DISAGREE stay UNRESOLVED: there is no basis to pick one.
    wirings = []
    for w in re.finditer(rb"=" + re.escape(fn.encode()) + rb"\((" + N + rb"),(" + N
                         + rb")\)\)\{let (" + N + rb")=0;function (" + N
                         + rb")\(\)\{if\(\3===0\)return;", data):
        tail = data[w.end(): w.end() + 400]
        if b"[plugin monitor" in tail and b"suppressed" in tail:
            wirings.append(w)
    pairs = sorted(set((w.group(1).decode(), w.group(2).decode()) for w in wirings))
    if not wirings:
        fail(f"no {fn}(...,...) call site feeding `[plugin monitor ... suppressed` within 400 bytes")
    elif len(pairs) != 1:
        fail(f"{len(pairs)} DISTINCT plugin-monitor wirings of {fn}: {pairs}")
    elif pairs[0] != (capn, refn):
        a, b = pairs[0]
        fail(f"monitor wiring uses {fn}({a},{b}), not the declared {capn},{refn}")
    else:
        w = wirings[0]
        print(f"  monitor wiring @{w.start()}: {fn}({capn},{refn}) feeds `[plugin monitor ... suppressed N events]`")
        out["bucket_capacity"] = int(cap)
        out["bucket_refill_ms"] = int(ref)

# 2. batcher + its constants + the monitor arming
g = re.search(rb"function (" + N + rb")\(e,t=\(n\)=>\{let o=setTimeout\(n,(" + N
              + rb")\);return\(\)=>clearTimeout\(o\)\}\)\{", data)
if not g:
    fail("batcher function G(e,t=(n)=>{let o=setTimeout(n,J);return()=>clearTimeout(o)}){")
else:
    gn, jn = g.group(1).decode(), g.group(2).decode()
    print(f"  batcher @{g.start()}: function {gn}(onBatch, timer=setTimeout(_,{jn}))")
    window = data[max(0, g.start() - 6000): g.start()]
    decls = list(re.finditer(rb"var (" + N + rb")=([0-9]+),(" + N + rb")=([0-9]+),("
                             + re.escape(jn.encode()) + rb")=([0-9]+),(" + N + rb")=1048576;", window))
    if not decls:
        fail(f"batcher constants var b=<n>,E=<n>,{jn}=<n>,L=1048576; within 6 KB before {gn}")
    else:
        d = decls[-1]  # the declaration nearest G
        ln, lv, bn, bv, _, jv, _ = (x.decode() for x in d.groups())
        body = data[g.end(): g.end() + 1500]
        line_ok = (b"c.length>" + ln.encode()) in body
        batch_ok = (b"a.length>" + bn.encode()) in body
        print(f"  batcher constants: var {ln}={lv},{bn}={bv},{jn}={jv},...=1048576  "
              f"(line-cut use `c.length>{ln}`: {line_ok}; batch-cut use `a.length>{bn}`: {batch_ok})")
        if not (line_ok and batch_ok):
            fail("the declared constants are not the ones the batcher cuts with")
        else:
            out["line_cut"] = int(lv)
            out["batch_cut"] = int(bv)
            out["batch_interval_ms"] = int(jv)
    arm = re.search(re.escape(gn.encode()) + rb"\((" + N + rb")\.onBatch\)", data)
    print(f"  monitor arming calls {gn}(<x>.onBatch): {bool(arm)}")
    if not arm:
        fail(f"no {gn}(<x>.onBatch) call: the batcher found is not the monitor's")

# At rc 3 the line LEADS with UNRESOLVED, so a reader who sees only the last
# line cannot take the partial (verified) values for a complete measurement.
print(f"RESULT [{label}] " + ("" if ok else "UNRESOLVED ")
      + " ".join(f"{k}={v}" for k, v in out.items())
      + ("" if ok else "  (INCOMPLETE)"))
sys.exit(0 if ok else 3)
