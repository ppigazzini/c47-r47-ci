#!/usr/bin/env bash
# scripts/test/run-upstream-contract.sh
#
# Check text this repository sends to upstream c43 against upstream's own word
# rules. Upstream AGENTS.md section 8.3 refuses a list of words in comments,
# commit notes and merge request text, and section 11 item 10 makes a refused
# word in a comment or in merge request text a rejection without review. The
# list is read out of a live clone rather than copied here: a copy drifts the
# moment upstream edits it, and a stale copy of a rejection rule is worse than
# none.
#
# It checks text, not this repository's own doc pages. docs/ is governed by
# docs/10-writing.md and is not sent upstream; a merge request body and the
# commit messages on a c43 branch are.
#
# Usage:
#   run-upstream-contract.sh --text FILE [--text FILE ...]
#   run-upstream-contract.sh --commits DIR RANGE
#
#   --text     a drafted merge request body, or any file whose text goes upstream
#   --commits  a c43 working tree and a commit range, e.g. origin/master..HEAD
#
# Environment: UPSTREAM_COMMIT pins the clone, UPSTREAM_DIR reuses one already
# on disk instead of fetching.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

TEXTS=()
COMMIT_DIR=""
COMMIT_RANGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --text) [[ $# -ge 2 ]] || harness_die "--text needs a file"; TEXTS+=("$2"); shift 2 ;;
        --commits)
            [[ $# -ge 3 ]] || harness_die "--commits needs a directory and a range"
            COMMIT_DIR="$2"; COMMIT_RANGE="$3"; shift 3 ;;
        -h | --help) sed -n '3,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) harness_die "unknown argument '$1'" ;;
    esac
done

[[ ${#TEXTS[@]} -gt 0 || -n "$COMMIT_DIR" ]] \
    || harness_die "nothing to check - pass --text FILE or --commits DIR RANGE"

harness_init

# Reuse a clone that already holds AGENTS.md; otherwise fetch one.
if [[ -f "$UPSTREAM_DIR/AGENTS.md" ]]; then
    harness_log "reusing the upstream tree at $UPSTREAM_DIR"
else
    commit="$(harness_resolve_commit)"
    harness_log "syncing upstream $commit for its AGENTS.md"
    harness_sync_upstream "$commit"
fi
UPSTREAM_SHA="$(git -C "$UPSTREAM_DIR" rev-parse --short HEAD 2> /dev/null || echo unknown)"
harness_log "word rules read from upstream AGENTS.md at $UPSTREAM_SHA"

WORKLIST="$LOG_DIR/upstream-contract-inputs.txt"
: > "$WORKLIST"
for f in ${TEXTS+"${TEXTS[@]}"}; do
    [[ -f "$f" ]] || harness_die "no such file: $f"
    printf 'text\t%s\t%s\n' "$f" "$f" >> "$WORKLIST"
done
if [[ -n "$COMMIT_DIR" ]]; then
    git -C "$COMMIT_DIR" rev-parse --git-dir > /dev/null 2>&1 \
        || harness_die "not a git tree: $COMMIT_DIR"
    n=0
    while read -r sha; do
        [[ -n "$sha" ]] || continue
        msg="$LOG_DIR/commit-$sha.txt"
        git -C "$COMMIT_DIR" log -1 --format=%B "$sha" > "$msg"
        printf 'commit\t%s\t%s\n' "$msg" "$(git -C "$COMMIT_DIR" log -1 --format='%h %s' "$sha")" >> "$WORKLIST"
        n=$((n + 1))
    done < <(git -C "$COMMIT_DIR" rev-list "$COMMIT_RANGE")
    harness_log "$n commit messages from $COMMIT_DIR $COMMIT_RANGE"
fi

python3 - "$UPSTREAM_DIR/AGENTS.md" "$WORKLIST" << 'PY'
import re, sys

agents, worklist = sys.argv[1], sys.argv[2]
text = open(agents, encoding="utf-8").read()

m = re.search(r"^### 8\.3(.*?)^## ", text, re.S | re.M)
if not m:
    sys.exit("section 8.3 not found in upstream AGENTS.md - the contract moved, update this lane")
sect = m.group(1)

rules = {}                                        # word -> replacement
for row in re.finditer(r"^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$", sect, re.M):
    left, right = row.group(1), row.group(2)
    if left.lower().startswith("refused") or set(left) <= set("- "):
        continue
    for w in re.findall(r"[A-Za-z]+", left.split(", in the sense")[0].split(", and every form")[0]):
        if w.lower() in ("and", "every", "form", "of", "it", "in", "the", "sense", "both", "senses"):
            continue
        rules.setdefault(w.lower(), right)

fill = re.search(r"Filler to delete on sight:\s*(.+?)\.", sect, re.S)
if fill:
    for w in [p.strip() for p in fill.group(1).split(",")]:
        if w:
            rules.setdefault(w.lower(), "delete it")

verbs = re.search(r"^`([a-z ]+)`$", sect, re.M)
if verbs:
    # Entries are separated by two or more spaces; one of them, "looks for", holds
    # a single space, so splitting on whitespace would refuse the preposition too.
    for w in re.split(r"\s{2,}", verbs.group(1).strip()):
        if w:
            rules.setdefault(w.lower(), "a verb that states the mechanism")

# Upstream exempts these by name in the prose of the same section.
for w in ("restore", "restart", "register"):
    rules.pop(w, None)

print("[contract] %d refused words read from section 8.3" % len(rules))

def strip_code(s):
    s = re.sub(r"```.*?```", lambda mm: "\n" * mm.group(0).count("\n"), s, flags=re.S)
    return re.sub(r"`[^`\n]*`", "", s)

pat = {w: re.compile(r"\b%s\b" % re.escape(w).replace(r"\ ", r"\s+"), re.I) for w in rules}
hits = total = 0
for line in open(worklist, encoding="utf-8"):
    kind, path, label = line.rstrip("\n").split("\t", 2)
    body = strip_code(open(path, encoding="utf-8").read())
    found = {}
    for i, ln in enumerate(body.split("\n"), 1):
        for w, p in pat.items():
            for _ in p.finditer(ln):
                found.setdefault(w, []).append(i)
    if found:
        hits += 1
        print("[contract] %s: %s" % (kind, label))
        for w in sorted(found, key=lambda k: -len(found[k])):
            total += len(found[w])
            print("             %-12s x%-3d lines %s -> %s"
                  % (w, len(found[w]), ",".join(str(x) for x in found[w][:6]), rules[w]))

if total:
    print("[contract] FAILED: %d refused words across %d inputs" % (total, hits))
    sys.exit(1)
print("[contract] PASSED: no refused word in the text checked")
PY
