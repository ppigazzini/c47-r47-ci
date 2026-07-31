#!/usr/bin/env python3
"""The c47 link graph: SCCs, CCD/ACD/NCCD, and the dispatch-split effect.

Implements the method docs/00-architecture.md Annex A states, so Section 8's
figures can be re-derived rather than trusted. Needs a built simulator:

    cd <c43-clone> && make simc47
    python3 scripts/test/tooling/linkgraph.py <c43-clone>/build.sim/src/c47-gtk/c47.p

An edge A->B exists iff A leaves a symbol undefined that B defines globally
(nm type T/D/B/R/W). That is whole-program truth from the linker's own view,
with no inference from includes or call syntax.

Two traps this encodes, both of which produce a confident wrong answer:

  - meson names a library object after its relative path, so every object from
    src/c47 begins ".._c47_". A shell glob treats those as dotfiles and skips
    them: c47.p/*.o matches 10 of 246. Enumerate the directory instead.
  - the library subset is the ".._c47_" objects. Including c47-gtk, t47 and the
    generated sources changes N, and every one of CCD, ACD and NCCD scales with
    N, so a graph over the wrong vertex set is not comparable to anything.
"""

import os
import subprocess
import sys
from collections import defaultdict

GLOBAL_TYPES = set("TDBRW")  # uppercase nm type == global
LIB_PREFIX = ".._c47_"


def nm(args, path):
    return subprocess.run(["nm", *args, path], capture_output=True, text=True).stdout.splitlines()


def symbols(objs):
    """defined-globals and undefined-symbols per object."""
    defines, undefs = {}, {}
    for o in objs:
        d = set()
        for line in nm(["--defined-only"], o):
            f = line.split()
            if len(f) >= 3 and f[-2] in GLOBAL_TYPES:
                d.add(f[-1])
            elif len(f) == 2 and f[0] in GLOBAL_TYPES:
                d.add(f[1])
        defines[o] = d
        undefs[o] = {line.split()[-1] for line in nm(["-u"], o) if line.split()}
    return defines, undefs


def tarjan(vertices, adj):
    index, low, onstack, stack, comps = {}, {}, set(), [], []
    counter = [0]

    def strong(root):
        work = [(root, iter(adj[root]))]
        index[root] = low[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        onstack.add(root)
        while work:
            node, it = work[-1]
            descended = False
            for w in it:
                if w not in index:
                    index[w] = low[w] = counter[0]
                    counter[0] += 1
                    stack.append(w)
                    onstack.add(w)
                    work.append((w, iter(adj[w])))
                    descended = True
                    break
                if w in onstack:
                    low[node] = min(low[node], index[w])
            if descended:
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[node])
            if low[node] == index[node]:
                comp = []
                while True:
                    w = stack.pop()
                    onstack.discard(w)
                    comp.append(w)
                    if w == node:
                        break
                comps.append(comp)

    for v in vertices:
        if v not in index:
            strong(v)
    return comps


def ccd_balanced_binary_tree(n):
    """Lakos's comparator: CCD of a balanced binary tree of n nodes."""
    if n <= 0:
        return 0
    left = (n - 1) // 2
    return n + ccd_balanced_binary_tree(left) + ccd_balanced_binary_tree(n - 1 - left)


def measure(vertices, adj):
    comps = tarjan(vertices, adj)
    trapped = sum(len(c) for c in comps if len(c) > 1)

    def reachable(v):
        seen, stack = {v}, [v]
        while stack:
            x = stack.pop()
            for y in adj[x]:
                if y not in seen:
                    seen.add(y)
                    stack.append(y)
        return len(seen)

    n = len(vertices)
    ccd = sum(reachable(v) for v in vertices)
    return {
        "n": n,
        "trapped": trapped,
        "largest_scc": max((len(c) for c in comps), default=0),
        "ccd": ccd,
        "acd": ccd / n,
        "nccd": ccd / ccd_balanced_binary_tree(n),
        "singletons": [c[0] for c in comps if len(c) == 1],
    }


def short(obj):
    """meson's object stem, minus the '.._c47_' prefix and the '.c.o' suffix.

    Left with underscores rather than prettied into a path: meson flattens the
    directory separator to '_', so pcg_basic.c and a directory named pcg are
    indistinguishable here and guessing produces a path that does not exist.
    """
    return os.path.basename(obj)[len(LIB_PREFIX) : -4]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    pdir = sys.argv[1]
    objs = sorted(os.path.join(pdir, f) for f in os.listdir(pdir) if f.endswith(".o"))
    if not objs:
        sys.exit(f"no objects under {pdir} - run `make simc47` first")

    defines, undefs = symbols(objs)
    owner = defaultdict(list)
    for o, d in defines.items():
        for s in d:
            owner[s].append(o)

    lib = [o for o in objs if os.path.basename(o).startswith(LIB_PREFIX)]
    if not lib:
        sys.exit(f"no {LIB_PREFIX}*.o objects under {pdir} - wrong .p directory?")
    libset = set(lib)

    adj = defaultdict(set)
    edges = 0
    for a in lib:
        for s in undefs[a]:
            for b in owner.get(s, ()):
                if b in libset and b != a and b not in adj[a]:
                    adj[a].add(b)
                    edges += 1

    m = measure(lib, adj)
    dupes = [s for s, os_ in owner.items() if len([o for o in os_ if o in libset]) > 1]
    total_globals = len(set().union(*(defines[o] for o in lib)))

    print(f"  objects linked                  {len(objs):>10}")
    print(f"  link units (src/c47)            {m['n']:>10}")
    print(f"  edges                           {edges:>10}")
    print(f"  files trapped in cycles         {m['trapped']:>10} = {round(100 * m['trapped'] / m['n'])}%   (largest SCC {m['largest_scc']})")
    print(f"  CCD                             {m['ccd']:>10}")
    print(f"  ACD                             {m['acd']:>10.1f}")
    print(f"  NCCD                            {m['nccd']:>10.2f}")
    print(f"  globals defined by >1 object    {len(dupes):>10} of {total_globals}")
    print("\n  outside the cycle: " + ", ".join(sorted(short(o) for o in m["singletons"])))

    # The dispatch-split effect Section 11 quotes: drop items.c's outgoing edges.
    items = next((o for o in lib if short(o) == "items"), None)
    if items is not None:
        split_adj = defaultdict(set)
        for a in lib:
            if a is not items:
                split_adj[a] = adj[a]
        sm = measure(lib, split_adj)
        print(
            f"\n  dispatch edges removed:  trapped {m['trapped']} -> {sm['trapped']},  ACD {m['acd']:.1f} -> {sm['acd']:.1f},  NCCD {m['nccd']:.2f} -> {sm['nccd']:.2f}"
        )


if __name__ == "__main__":
    main()
