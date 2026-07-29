#!/usr/bin/env bash
# scripts/test/run-docs-citations.sh
#
# Citation-drift gate for the upstream-tracking pages in docs/.
#
# Those pages cite upstream source as `file.c:123`, usually paired with the
# symbol the line holds: `stack.c:21` `liftStack`. A line number is the one kind
# of claim in this repo that rots silently - upstream inserts twenty lines above
# it and the citation now points at a closing brace, with nothing failing. This
# gate resolves every citation against a live clone and reports the ones that
# moved, so the number is owned by a script rather than by prose.
#
# Two checks per citation:
#   1. the file exists, and the line is inside it;
#   2. where the page also names a symbol, that symbol still appears on the
#      cited line. A citation with no symbol is reported as UNANCHORED, not
#      failed - it cannot be checked, and that is worth knowing. Only a symbol
#      written next to the citation counts as an anchor - `sym` (`file.c:N`) or
#      `file.c:N` `sym`, the two shapes the pages use. A backticked word further
#      away - the next column of a table, say - is not a claim about that line
#      and is not treated as one. A range `file.c:N-M` passes when the symbol
#      lands anywhere inside it.
#
# Resolution is by full path suffix, never by basename alone: the GMP subproject
# ships its own memory.c and config.c, and matching on the basename resolves a
# c47 citation against one of those and invents drift that is not there.
#
# Report-only by default. CITATIONS_GATE=1 makes a moved citation fatal.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
: "${CITATIONS_GATE:=0}"

main() {
    harness_init
    local log="$LOG_DIR/docs-citations.log"
    {
        local commit
        commit="$(harness_resolve_commit)"
        harness_log "upstream commit: $commit"
        harness_sync_upstream "$commit"

        python3 - "$REPO_ROOT" "$UPSTREAM_DIR" "$commit" << 'PY'
import re, os, sys, glob, collections

repo, tree, commit = sys.argv[1], sys.argv[2], sys.argv[3]

# Index by full relative path; a citation matches on a path suffix so that
# src/c47/memory.c never resolves to subprojects/gmp-6.2.1/memory.c.
paths = []
for root, dirs, files in os.walk(tree):
    dirs[:] = [d for d in dirs if d not in (".git",) and not d.startswith("build")]
    for f in files:
        if f.endswith((".c", ".h")):
            paths.append(os.path.relpath(os.path.join(root, f), tree))
by_base = collections.defaultdict(list)
for p in paths:
    by_base[os.path.basename(p)].append(p)

# `file.c:123` optionally followed by `symbol`
# `sym` (`file.c:N`)  |  `file.c:N` `sym`  |  | `sym` | ... | `file.c:N` |
cite = re.compile(r'(?:`([A-Za-z_][A-Za-z0-9_]*)`\s*\()?'
                  r'`(?:\.\./c43/)?([A-Za-z0-9_./-]+\.[ch]):(\d+)(?:-(\d+))?`'
                  r'(?:\s+`([A-Za-z_][A-Za-z0-9_]*)`)?')

total = ambiguous = unanchored = moved = broken = 0
findings = []

for page in sorted(glob.glob(os.path.join(repo, "docs", "*.md"))):
    rel = os.path.relpath(page, repo)
    for ln, line in enumerate(open(page, errors="replace"), 1):
        for m in cite.finditer(line):
            before, f, n = m.group(1), m.group(2), int(m.group(3))
            end = int(m.group(4)) if m.group(4) else n
            sym = m.group(5) or before
            total += 1
            cands = [p for p in by_base.get(os.path.basename(f), []) if p.endswith(f)]
            # prefer the product tree when a basename is shared with a subproject
            product = [p for p in cands if p.startswith("src/")]
            cands = product or cands
            if not cands:
                broken += 1
                findings.append(f" GONE       {rel}:{ln}  {f}:{n} - no such file upstream")
                continue
            if len(cands) > 1:
                ambiguous += 1
            src = open(os.path.join(tree, cands[0]), errors="replace").read().splitlines()
            if n > len(src):
                broken += 1
                findings.append(f" PAST-EOF   {rel}:{ln}  {f}:{n} - {cands[0]} has {len(src)} lines")
                continue
            if before and not m.group(5) and line[m.end():m.end() + 1] == ",":
                sym = None           # `A` / `B` (`f:x`, `f:y`) - which symbol is which is not stated
            if not sym:
                unanchored += 1
                continue
            if any(sym in l for l in src[n - 1:min(end, len(src))]):
                continue
            word = re.compile(r'(^|[^A-Za-z0-9_])' + re.escape(sym) + r'($|[^A-Za-z0-9_])')
            hits = [i + 1 for i, l in enumerate(src)
                    if word.search(l) and not l.lstrip().startswith(("//", "*"))]
            # A citation names where a thing IS, so rank declaration sites over uses:
            # a function definition, then #define / extern / enumerator, then a call.
            calls = [i for i in hits if re.search(re.escape(sym) + r'\s*\(', src[i - 1])]
            fndef = [i for i in calls if not src[i - 1].rstrip().endswith(";")
                     and not src[i - 1].lstrip().startswith(("if", "while", "for", "switch", "return"))]
            decl = [i for i in hits if re.search(
                        r'^\s*(#\s*define\s+' + re.escape(sym) + r'\b'
                        r'|extern\b.*\b' + re.escape(sym) + r'\s*[\[;]'
                        r'|[A-Za-z_][A-Za-z0-9_ *]*\b' + re.escape(sym) + r'\s*(\[[^]]*\])?\s*[;=]'
                        r'|' + re.escape(sym) + r'\s*(=[^,]*)?,\s*(//.*)?$)', src[i - 1])]
            pick = fndef or decl or calls or hits
            if not hits:
                unanchored += 1      # the word is nowhere in the file: prose, never a claim
                continue
            moved += 1
            findings.append(f" MOVED      {rel}:{ln}  {f}:{n} `{sym}` -> now :{pick[0]}")

print(f"citations checked: {total}  (anchored to a symbol: {total - unanchored}, unanchored: {unanchored})")
print(f"resolved against upstream {commit}")
for f in findings:
    print(f)
print(f"broken: {broken}   moved: {moved}")
sys.exit(1 if (broken or moved) else 0)
PY
        local rc=$?
        if ((rc != 0)); then
            if ((CITATIONS_GATE)); then
                harness_die "citation drift (CITATIONS_GATE=1)"
            fi
            harness_log "citation drift found - report-only (CITATIONS_GATE=1 to gate)"
        else
            harness_log "DOCS CITATIONS OK"
        fi
    } 2>&1 | tee "$log"
    harness_log "log written: $log"
}

main "$@"
