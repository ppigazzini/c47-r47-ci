# Writing these docs

How this set is organised, what a page here must be true about, and what the
gate does and does not check. Read it before adding or editing a page.

## The set

`README.md` is the index - GitHub renders it for the folder, so it is what a
reader lands on. The rest are `00-` to `07-`, numbered by **reading order**, not
importance: a contributor works down from the architecture into a subsystem, out
through the build into testing, debugging and the lanes. The prefix is the only
ordinal; nothing else numbers them.

Each page owns one subject and names its **audience** in the index table. A page
describes **what is true here** - what C47 does, or what this harness does. It
is not a calculator tutorial and not an RPN primer. Anything a reader could get
from upstream's wiki or a vendor manual belongs in
[06-references.md](06-references.md) as a link.

Two repositories are in scope and they are not the same thing. Upstream c43 on
GitLab is the product; this repo is the harness that builds it. Say which one a
sentence is about. A reader who cannot tell will look for `run-leakscan.sh` in
the product tree and not find it.

## The rules

Each one is here because breaking it cost this project real time.

**A plausible explanation is not evidence.** The `--testmem` baseline carried an
entry for `toReal` with the rationale *"the SHOI->real conversion caches a
scratch real in the pool"*. That sentence is fluent, technical, and invented.
There was no leak: the scanner's high-water bound was assigned unconditionally,
so a case that *released* memory moved the bar and the next case was measured
against a level no case reached. The invented rationale is what let the artefact
survive two rebaselines - it read like someone had checked. If you cannot name
the evidence, write "unexplained" and leave it visible.

**Never rebless a finding you have not root-caused.** A baseline is a list of
claims. `ci(test): regenerate the lane baselines` is not a reason for an entry to
exist; it is the absence of one. When the leak gate changed in both directions at
once, each direction needed its own answer: the 11 removed entries were tied to
the upstream commit that fixed them (`3bd0f13ea`, confirmed by pinning
`UPSTREAM_COMMIT` either side of it), and the 2 added entries were bisected to
the commit that exposed them. Regenerating without that is laundering.

**Name the owner and the invariant, not just the mechanism.** Say which file and
symbol owns the behaviour and what must stay true about it. "`dynamicMenuItem`
selects a dynamic menu item" is accurate and useless. The fact a reader needs is
that **-1 means nothing is selected**, that `c47.c` documents it, and that
`fnSolveVar` and `fnIntVar` index with it anyway - which is why a headless call
segfaults. Write the sentence a reader needs before they delete your line.

**Verify against the tree; drive the binary when the claim is behavioural.** Not
"read it carefully" - run it. This set shipped claims that a single command
disproved in seconds. The lanes are the instrument: every one takes
`UPSTREAM_COMMIT`, so any claim about upstream behaviour can be pinned to a
commit and re-run.

**Describe a gap as a gap, never as a design.** "The corpus tests computation"
sounds like a scope decision. The fact is that **nothing asserts the screen**, so
a display regression passes CI. Framing a hole as a choice is what keeps it
alive: nobody fixes a design. If something is missing, say missing, and say what
it costs.

**Never pin a number the repo computes.** Baseline entry counts, pass counts,
warning counts. `docs/05-ci.md` pinned the leakscan baseline at "(39)"; a
rebaseline made it 30 in the same session and the doc was not touched. Check 3 of
the gate now owns exactly that number - quote the file, not the figure, for
anything it does not cover.

**State the limit.** A page that omits its own boundary invites over-trust. "Run
a lane the way CI runs it - the script is the contract" is true for every lane
except coverage, whose gates live in the workflow (`COVERAGE_MIN`,
`SECTOR_GATE`). The sentence without its exception sends a reader to reproduce a
CI failure that cannot reproduce. Say what the thing does *not* cover.

**Separate upstream fact from local decision.** "Upstream `make test` fails 6
tests" is checkable against a pinned sha. "This lane gates hard because X" is a
choice someone must be able to revisit. Blur them and a reader cannot tell which
they are allowed to change.

**No history.** "Used to be X", "fixed in Y", "previously a stub" is out of date
the day after and tells a reader nothing about what is in front of them. The
before and after belongs in the commit message - that, plus the code, is the
durable record.

**Show the command.** "The leak gate is clean" is not a claim; the script name,
its knobs and its exit code are. A behaviour claim ships with what produced it so
the next reader can re-run it instead of trusting you.

**One example beats three paragraphs**, and **pair every prohibition with an
alternative**. "Don't hand-edit `leakscan.patch`" leaves a reader stuck; "don't
hand-edit it - hunk headers count lines, so apply it to a clean tree, edit there,
and `git diff` back" does not.

**Cut anything that does not help implement or verify.** Length is not
thoroughness; it is where rot hides.

## Hot and cold

These pages do not age alike, and treating them the same is why they rot. A page
is **hot** when it describes something that moves - it is a running claim about a
tree someone is changing today. It is **cold** when what it describes barely
moves.

**Change hot code, re-read its page in the same commit.** Not "later": a doc is
wrong from the moment the change lands, and nobody knows which claim broke better
than the person who broke it. The one stale number this set has carried got there
exactly that way, in the session that changed it.

| page | owns | temperature |
|---|---|---|
| [00-architecture.md](00-architecture.md) | what C47 is: the god header, the item table, the HAL, the dependency graph | hot - tracks upstream |
| [01-codebase.md](01-codebase.md) | the c43 source tree, the register file, the memory model, control flow | hot - tracks upstream |
| [02-build.md](02-build.md) | upstream's `make` targets, the Meson graph, the generators, packaging | hot - tracks upstream |
| [03-testing.md](03-testing.md) | the corpus, the three drivers, how to write a test | hot - tracks upstream |
| [04-debugging.md](04-debugging.md) | the detectors and the false-pass catalogue | hot - tracks this repo |
| [05-ci.md](05-ci.md) | the lane contract, the workflow-to-script map, the baselines | hot - tracks this repo |
| [06-references.md](06-references.md) | external links | cold |
| this page | the rules | cold |

The hot rows split by what they track, and the distinction matters: rows 0-3
describe a tree **this repo does not control**, so they rot when upstream moves
and nothing here changed. That is the failure the leak gate hit - upstream moved
`a361b6797` to `87c70c77a` and three lanes broke without a commit here. Pages
that track upstream need re-reading on an upstream sync, not only on a local
change.

Cold does not mean unowned. It means the claim outlives a release, so when it
*is* wrong it has usually been wrong for a long time.

## Code comments

This repo's own code is shell. Same rules, plus these.

**Imperative mood, leading with a verb.** "Resolve the upstream commit", not
"Returns the commit" or "This function resolves...". A comment is an order to the
reader, not a description of the author.

**Write only the constraint the code cannot show.** Never restate the next line.
Never say where the code came from or why your change is right - that is the
commit message's job, and it is noise the moment the change merges.

**Name the invariant and what breaks without it.** The lane scripts do this well;
keep it:

```sh
# Tolerate an all-comment baseline (every finding fixed): grep -v then matches
# nothing and exits 1, which pipefail+set -e would turn into a spurious abort.
```

That comment survives a refactor. "Filter the comments" does not.

**Never explain an oddity into a convention.** If you are writing a sentence that
makes a strange thing sound intended, stop and check whether it is a bug. That
sentence is load-bearing for the next reader who might otherwise have fixed it.

## Commits

Conventional subject, `type(scope): summary`, scope a single token
(`fix(matrixEditor)`, not `fix(matrix editor)`). Body wrapped at 80, imperative
mood, carrying the **evidence**: the command, its output, its exit code. Not
"should work".

- **No historical narration and no meta commentary** about the process that
  produced the change.
- **Never add a `Co-Authored-By` or generated-by trailer** in this repo.
- A commit that changes a number a doc pins changes the doc too, in the same
  commit.

## The gate

`bash scripts/test/run-docs-lint.sh` (CI lane: Docs Lint) fails on:

1. a dead internal link, resolved relative to the linking file's own directory,
2. a backticked `scripts/...` or `.github/...` path named in prose that does not
   exist - a bare filename like `run-smoke.sh` is **not** checked; write the path
   if you want the gate to hold it,
3. a baseline entry count quoted as `` `<name>-baseline.txt` (N) `` that
   disagrees with the file,
4. a non-ASCII byte in a tracked doc,
5. a tracked doc citing a path under `__DEV/`, which is gitignored and therefore
   unreadable for every reader who is not the maintainer.

It needs no upstream clone and no toolchain, so it runs in seconds on every push.

**It cannot tell you a sentence is false.** The invented `toReal` rationale
parsed, linked, named no dead path, and pinned no number - and was fiction for
three weeks. No grep finds that; only reading does. The gate buys the mechanical
half so review can spend its attention on the half that needs a reader.

That is the failure mode to write against: docs here are accurate when written
and rot where the thing under them moves - especially upstream, which moves
without asking. Prefer the claim that stays true: name the owner and the
invariant, and point at the command for the number.
