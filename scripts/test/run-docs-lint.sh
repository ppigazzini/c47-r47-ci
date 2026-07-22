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
#   * Four pages describe upstream, which moves without a commit here. Two named
#     the commit they were measured at and two named nothing at all, so a reader
#     could not tell a page checked last week from one never checked.  -> check 7
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

# Tracked files AND untracked-but-not-ignored ones: a brand new page is exactly
# the page most likely to be wrong, and listing only --cached skips it until the
# commit that adds it has already been made. --exclude-standard keeps __DEV/ and
# the build dirs out. Sort -u because the two lists overlap.
mapfile -t DOCS < <(git ls-files --cached --others --exclude-standard '*.md' | sort -u)
log "docs rot gate over ${#DOCS[@]} markdown files (tracked and new)"

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

# --- 3b. cross-page section references resolve --------------------------------
# Check 1 validates the file half of a link and stops at the closing paren, so
# the " s9" or " Section 12" that follows is unchecked prose. Renumbering a
# target page silently invalidates every reference into it: six such references
# were found dangling at once, five of them in one file.
n=0
for f in "${DOCS[@]}"; do
    while IFS='|' read -r target sect; do
        [[ -n "$target" ]] || continue
        tgt="$(dirname "$f")/$target"
        [[ -e "$tgt" ]] || continue          # check 1 owns a missing file
        # A page's own headings, as "N" or "N.M"
        # Headings, or the bold numbered sub-sections 00-architecture uses
        if ! grep -qE "^#{2,4} ${sect}[. ]|^\\*\\*${sect} " "$tgt"; then
            note "DEAD SECTION  $f -> $target s$sect (no such heading)"
            n=$((n + 1))
        fi
    done < <(grep -ohE '\(([0-9]{2}-[a-z-]+\.md)\)[^.]{0,4}(s|Section )([0-9]+(\.[0-9]+)?)' "$f" |
             sed -E 's/^\(([^)]+)\).*(s|Section )([0-9]+(\.[0-9]+)?)$/\1|\3/')
done
log "check 3b: cross-page section references resolve ($n dead)"

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

# --- 7. the upstream-tracking pages declare an audit basis --------------------
# Four pages describe a tree this repo does not control, so they rot when
# upstream moves and nothing here changes: that is how a361b6797 -> 87c70c77a
# broke three lanes with no commit here. Before this check, 00 and 01 named the
# commit they were measured at and 02 and 03 named nothing, so a reader could
# not tell an unchecked page from a checked one.
#
# Two legal forms, both one line:
#   Audit basis: upstream `<40-hex>`, YYYY-MM-DD.
#   Audit basis: none recorded.
# The second is not a loophole - it is the honest value, and it is visible in
# the rendered page, which "no line at all" is not.
#
# The SHA must be all 40 characters, matching what common.sh already demands of
# UPSTREAM_COMMIT: an abbreviation is ambiguous against a growing history and
# cannot be fed straight back to a lane to re-verify the page.
#
# The LIMIT, and it is the whole point of writing it down: this checks that a
# stamp exists and parses. It cannot check that anyone read the page at that
# commit. Upstream here is deliberately unpinned - every lane resolves master at
# runtime - so there is no file to diff a stamp against, and a stamp is a claim
# with the same shelf life as the prose under it. It dates the claim; it does
# not verify it.
n=0
for page in 00-architecture 01-codebase 02-build 03-testing; do
    f="docs/$page.md"
    [[ -e "$f" ]] || { note "MISSING PAGE  $f (named in the audit-basis list)"; n=$((n + 1)); continue; }
    basis="$(grep -m1 '^Audit basis:' "$f" || true)"
    if [[ -z "$basis" ]]; then
        note "NO BASIS      $f has no 'Audit basis:' line (use 'none recorded' if it has never been checked)"
        n=$((n + 1))
    elif [[ "$basis" != "Audit basis: none recorded." ]] \
        && ! [[ "$basis" =~ ^Audit\ basis:\ upstream\ \`[0-9a-f]{40}\`,\ [0-9]{4}-[0-9]{2}-[0-9]{2}\.$ ]]; then
        note "BAD BASIS     $f: '$basis' is neither 'none recorded.' nor 'upstream \`<40-hex>\`, YYYY-MM-DD.'"
        n=$((n + 1))
    fi
done
log "check 7: upstream-tracking pages declare an audit basis ($n problems)"

if [[ "$fail" -ne 0 ]]; then
    log "DOCS GATE FAILED"
    exit 1
fi
log "docs gate PASSED"
