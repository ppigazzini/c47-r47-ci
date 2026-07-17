#!/usr/bin/env bash
# scripts/test/run-docs-lint.sh
#
# Docs rot gate. The tracked docs must not make a claim this repo contradicts.
#
# Docs here are accurate when written and rot where the thing under them moves.
# This checks the rot classes a machine can settle; whether a sentence is TRUE
# still needs a reader. Unlike every other lane it needs no upstream clone: it
# only reads this repo, so it is fast and runs on every push.
#
# Every check below is paid for by a defect this repo actually shipped:
#
#   * The doc set was renumbered 0N- -> NN- and the index moved to README.md.
#     That rewrote ~90 cross-references in one pass. A typo in any of them is a
#     dead link the reader hits and the author never does.  -> check 1
#   * Docs name their owner constantly ("run-leakscan.sh", "test-valgrind.yml").
#     A rename leaves the prose reading perfectly and pointing at nothing.
#     -> check 2
#   * docs/05-ci.md pinned the leakscan baseline at "(39)". A rebaseline against
#     a moved upstream made it 30 in the same session, and the doc was not
#     touched: the commit that changed the number is exactly the commit that
#     should have changed the doc.  -> check 3
#   * "ASCII by default" and "never cite __DEV/ from a tracked file" are stated
#     as non-negotiable in AGENTS.md and were enforced by nothing. __DEV/ is
#     gitignored, so a citation into it is a dangling reference for every reader
#     who is not the maintainer.  -> checks 4 and 5
#
# NOT checked, deliberately: whether a sentence is true. A baseline rationale
# reading "the SHOI->real conversion caches a scratch real in the pool" parses,
# links, and names no dead path - and was invented. Only a reader catches that.
# This gate buys the mechanical half so review can spend attention on the rest.
#
# Usage:  bash scripts/test/run-docs-lint.sh     # from anywhere
# Exit:   0 all checks pass, 1 a tracked doc contradicts the repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail=0
note() { printf 'docs-lint: %s\n' "$*"; fail=1; }

mapfile -t DOCS < <(git ls-files '*.md')
log "docs rot gate over ${#DOCS[@]} tracked markdown files"

# --- 1. every internal link resolves ------------------------------------------
# Resolve relative to the LINKING FILE's directory, not the cwd: docs/README.md
# links to "05-ci.md", which only exists as docs/05-ci.md. Checking these from
# the repo root reports every one of them as broken.
n=0
for f in "${DOCS[@]}"; do
    dir="$(dirname "$f")"
    while IFS= read -r target; do
        case "$target" in http*|mailto*|"") continue ;; esac
        path="${target%%#*}"          # strip the #anchor
        [[ -n "$path" ]] || continue  # a bare #anchor is intra-file
        [[ -e "$dir/$path" ]] || note "BROKEN LINK   $f -> $target"
        [[ -e "$dir/$path" ]] || n=$((n + 1))
    done < <(grep -oE '\]\([^) ]+\)' "$f" | sed 's/^](//; s/)$//')
done
log "check 1: internal links resolve ($n broken)"

# --- 2. every repo path named in prose exists ---------------------------------
# Only backticked paths under the directories this repo owns. A bare filename
# ("run-smoke.sh") is not checked - write the path if you want the gate to hold
# it. An ellipsis marks a placeholder ("scripts/..."), not a claim that a file
# exists, so those are skipped: prose has to be able to name a shape.
n=0
while IFS= read -r p; do
    case "$p" in *...*) continue ;; esac
    [[ -e "$p" ]] || { note "DEAD PATH     $p (named in a tracked doc, not in this repo)"; n=$((n + 1)); }
done < <(grep -ohE '`(scripts|\.github)/[A-Za-z0-9_/.-]+`' "${DOCS[@]}" \
         | tr -d '`' | grep -vE '/$' | sort -u)
log "check 2: repo paths named in prose exist ($n dead)"

# --- 3. a baseline count quoted in a doc matches the baseline -----------------
# The baselines move whenever upstream moves. The count is the single fact a doc
# is most likely to pin and least likely to revisit, so it is the one number
# this gate owns. Source of truth: the baseline file itself.
n=0
for b in scripts/test/*-baseline.txt; do
    [[ -e "$b" ]] || continue
    name="$(basename "$b")"
    actual="$(grep -vcE '^\s*(#|$)' "$b")"
    # Match the doc idiom: `<name>` (<count>)
    while IFS= read -r quoted; do
        [[ "$quoted" == "$actual" ]] || {
            note "STALE COUNT   $name quoted as ($quoted), file has $actual entries"
            n=$((n + 1))
        }
    done < <(grep -ohE "\`$name\` \([0-9]+\)" "${DOCS[@]}" | grep -oE '\([0-9]+\)' | tr -d '()')
done
log "check 3: quoted baseline counts match their baseline ($n stale)"

# --- 4. tracked docs are ASCII ------------------------------------------------
# AGENTS.md rule. An em dash or smart quote arrives by paste and survives review.
n=0
for f in "${DOCS[@]}"; do
    if LC_ALL=C grep -qP '[^\x00-\x7F]' "$f" 2> /dev/null; then
        note "NON-ASCII     $f: $(LC_ALL=C grep -oP '[^\x00-\x7F]' "$f" | sort -u | tr -d '\n')"
        n=$((n + 1))
    fi
done
log "check 4: tracked docs are ASCII ($n violations)"

# --- 5. no tracked doc cites a path under __DEV/ ------------------------------
# __DEV/ is gitignored and maintainer-only: a citation into it is unreadable for
# everyone else. Naming the directory to state that rule is allowed; pointing at
# a file inside it is not.
n=0
while IFS= read -r hit; do
    note "CITES __DEV/  $hit"
    n=$((n + 1))
done < <(grep -nE '__DEV/[A-Za-z0-9_.-]+' "${DOCS[@]}" | grep -vE '^\S*:\s*#')
log "check 5: no tracked doc cites a file under __DEV/ ($n citations)"

# --- 6. the agent contract is loadable ----------------------------------------
# AGENTS.md is the cross-tool convention; Claude Code reads CLAUDE.md and never
# AGENTS.md, so CLAUDE.md's `@AGENTS.md` import is the only thing that makes the
# contract load at all. Claude Code's import parser SKIPS code spans and fenced
# blocks, so backticking or fencing that line silently loads nothing - it still
# renders fine on GitHub, which is what makes it worth a gate.
n=0
for f in AGENTS.md CLAUDE.md; do
    [[ -f "$f" ]] || { note "MISSING       $f (the agent contract)"; n=$((n + 1)); }
done
if [[ -f CLAUDE.md ]]; then
    # Strip fenced blocks, then require a bare (unbackticked) @AGENTS.md line.
    if ! awk '/^```/{f=!f; next} !f' CLAUDE.md | grep -qE '^[[:space:]]*@AGENTS\.md[[:space:]]*$'; then
        note "IMPORT DEAD   CLAUDE.md has no bare '@AGENTS.md' line (backticked, fenced or gone: Claude Code would load nothing)"
        n=$((n + 1))
    fi
fi
log "check 6: the AGENTS.md/CLAUDE.md contract is loadable ($n problems)"

if [[ "$fail" -ne 0 ]]; then
    log "DOCS GATE FAILED"
    exit 1
fi
log "docs gate PASSED"
