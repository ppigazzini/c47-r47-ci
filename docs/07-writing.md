# Writing

The rules for everything this repo writes for a reader: the **doc pages**, the
**code comments**, and the **commit messages**. One set of rules, because all
three fail the same way; then what is specific to each.

Read it before writing any of the three.

## The rules

These hold for a page, a comment, and a commit body alike. Each one is here
because breaking it cost this project real time.

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
once, each direction needed its own answer: the removed entries were tied to the
upstream commit that fixed them (`3bd0f13ea`, confirmed by pinning
`UPSTREAM_COMMIT` either side of it), and the added ones were bisected to the
commit that exposed them. Regenerating without that is laundering.

**Never copy a fact a file already states. Cite the file, or gate the copy.**
`docs/05-ci.md` copied the leakscan baseline's entry count into a table. A
rebaseline changed the file and not the copy, in the same session. A copy of
machine-readable state is a claim with a shelf life measured in commits: quote
the file, or make a gate own the number. Check 3 of `run-docs-lint.sh` owns that
one now.

**Never pin a number the repo computes.** Baseline counts, pass counts, coverage
percentages, warning counts. `04-debugging.md` pinned five coverage percentages
to prove a driver fix worked; `run-coverage.sh` computes them and upstream moves
them. Quote the command and let the reader run it.

**Name the owner and the invariant, not just the mechanism.** Say which file and
symbol owns the behaviour and what must stay true about it. "`dynamicMenuItem`
selects a dynamic menu item" is accurate and useless. The fact a reader needs is
that **-1 means nothing is selected**, that `c47.c` documents it, and that
`fnSolveVar` and `fnIntVar` index with it anyway - which is why a headless call
segfaults. Write the sentence a reader needs before they delete your line.

**Describe a gap as a gap, never as a design.** "The corpus tests computation"
sounds like a scope decision. The fact is that **only `graphs_cov.txt` asserts
the screen**, so a regression anywhere else in the display passes CI. Framing a
hole as a choice is what keeps it alive: nobody fixes a design. If something is
missing, say missing, say how far the exception reaches, and say what it costs.

**Never rationalise a defect into a convention.** When you find yourself
explaining why the odd thing is fine, check whether it is. Written down as
behaviour, the mask becomes the spec and the bug underneath it is permanent.

**State the limit.** Anything that omits its own boundary invites over-trust:

- "the script is the contract" holds for every lane **except coverage**, whose
  gates live in the workflow (`COVERAGE_MIN`, `SECTOR_GATE`), so the bare script
  cannot reproduce a CI coverage failure
- `UPDATE_BASELINE=1` does **not** update the baseline; it writes `.new` and
  returns 0
- the lanes share one upstream tree, so two at once corrupt each other whatever
  their `BUILD_DIR` says

Say what the thing does *not* cover.

**Verify the claim against the tree; run the command when it is behavioural.**
Not "read it carefully" - run it. This set shipped a `build.cov` that exists
nowhere; the real directory is `build.coverage`, and one `grep` said so. The
lanes are the instrument: every one takes `UPSTREAM_COMMIT`, so a claim about
upstream can be pinned to a commit and re-run.

**Separate upstream fact from local decision.** "Upstream `make test` fails 6
tests" is checkable against a pinned sha. "This lane gates hard because X" is a
choice someone must be able to revisit. Blur them and a reader cannot tell which
they are allowed to change.

**No history outside the commit.** "Used to be X", "fixed in Y", "previously a
stub" is out of date the day after and tells a reader nothing about what is in
front of them. The before and after belongs in the commit message - that, plus
the code, is the durable record.

**One example beats three paragraphs**, and **pair every prohibition with an
alternative**. "Don't hand-edit `leakscan.patch`" leaves a reader stuck; "don't
hand-edit it - hunk headers count lines, so apply it to a clean tree, edit there,
and `git diff` back" does not.

**Cut anything that does not help implement or verify.** Length is not
thoroughness; it is where rot hides.

## Doc pages

`README.md` is the index - GitHub renders it for the folder, so it is what a
reader lands on. The rest are `00-` to `07-`, numbered by **reading order**, not
importance: a contributor works down from the architecture into a subsystem, out
through the build into testing, debugging and the lanes. The prefix is the only
ordinal; nothing else numbers them.

Each page owns one subject, names its **audience** in the index table, and opens
with its contract: the shortest accurate statement of what it covers. A page
describes **what is true here** - what C47 does, or what this harness does. It is
not a calculator tutorial and not an RPN primer. Anything a reader could get from
upstream's wiki or a vendor manual belongs in
[06-references.md](06-references.md) as a link.

Two repositories are in scope and they are not the same thing. Upstream c43 on
GitLab is the product; this repo is the harness that builds it. Say which one a
sentence is about. A reader who cannot tell will look for `run-leakscan.sh` in
the product tree and not find it.

`../AGENTS.md` is the committed agent contract and the short form of all of it.
It carries the commands, the traps and the definition of done, and it points here
rather than restating. Keep the duplication at zero: a rule lives in exactly one
of the two.

### Hot and cold

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
| [08-glossary.md](08-glossary.md) | what the words mean, product and harness | mixed - see below |
| [09-modules.md](09-modules.md) | the high-level module inventory and its literature terms | hot - tracks upstream |

The hot rows split by what they track, and the distinction matters: rows 0-3
describe a tree **this repo does not control**, so they rot when upstream moves
and nothing here changed. That is the failure the leak gate hit - upstream moved
`a361b6797` to `87c70c77a` and three lanes broke without a commit here. Pages
that track upstream need re-reading on an upstream sync, not only on a local
change.

Cold does not mean unowned. It means the claim outlives a release, so when it
*is* wrong it has usually been wrong for a long time.

**A page can be both, and the glossary is the one that is.** What a word means
barely moves; the `file:line` beside it moves every time upstream edits that
file. Splitting a page's temperature by *column* rather than by page is the
honest reading, and the page says so where a reader will hit it: grep the symbol
when a citation misses, rather than assuming the definition went with it.

### The audit basis

Because those four pages rot without a commit here, each one states, on its own
line directly under the title, the commit it was last read against:

```
Audit basis: upstream `<40-character sha>`, YYYY-MM-DD.
```

The SHA is full-length because that is what `UPSTREAM_COMMIT` accepts, so a
reader can paste it straight back into a lane and re-derive the page's claims.

When a page has never been checked, the line reads `Audit basis: none
recorded.` and the page says so in prose. **That is the honest value, not a
loophole.** An unchecked page with no line looks exactly like a checked one; an
unchecked page that says "none recorded" tells a reader how much to trust it and
tells a maintainer what to do next. `03-testing.md` carries it today.

**State the limit, because this one is easily overread.** Check 7 verifies that
a stamp exists and parses. It cannot verify that anyone read the page at that
commit - a stamp is prose, with the same shelf life as the prose under it.
Upstream here is deliberately unpinned; every lane resolves `master` at runtime,
so there is no file in this repo to diff a stamp against. It dates a claim. It
does not check one.

## Code comments

This repo's own code is shell; the product it drives is C. The rules above hold,
plus these.

**A comment lives two lives.** As you code and debug it is a **breadcrumb** - the
history, the hypothesis, the value that surprised you all earn their place. Once
the change merges it is a **fact**, and none of that survives. Write the
breadcrumbs freely, then compact every one to the form below in the same pass as
the commit; they always come out too long. A comment reaches the diff only if it
is still necessary once the code reads plainly - if the line speaks for itself,
say nothing.

**Present tense, about what is there now.** Imperative, leading with a verb:
"Resolve the upstream commit", not "Returns the commit", "This function
resolves...", or "used to be a stub".

**State the invariant the code keeps, never the bug that motivated it.** "uvw to
keep ll positive", not "xyz because ll went negative". The failure is history;
the standing guarantee is the fact. The lane scripts do this well:

```sh
# Tolerate an all-comment baseline (every finding fixed): grep -v then matches nothing and exits 1, which pipefail+set -e would turn into a spurious abort.
```

That comment survives a refactor. "Filter the comments" does not.

**No history, no meta.** Not "was X", not "fixed in Y", not "the following block
does". Why your change is right is the commit's job, and noise the moment it
merges.

**Say why code is absent when the absence is deliberate.** The reader cannot see
a check that is not there - `run-docs-lint.sh` says why it does not hold a bare
filename, so nobody "fixes" it into a false-positive machine.

**Cite upstream as `file:line` when mirroring it.** `src/c47/c47.c:259` is
checkable against a sha; "upstream does this too" is not.

**Never explain an oddity into a convention.** If a sentence makes a strange
thing sound intended, stop and check whether it is a bug - that sentence is
load-bearing for the next reader who might otherwise have fixed it.

**Terse, and wide.** Keep to the fact and cut every word that is not it. Wrap
comments at **160-170 columns**, never at 80 - a short wrap costs the maintainer
a reflow on every read. Do not break before column 160 unless a punctuation mark
falls between 150 and 170; then break there, ending the line on one of
`, . ; : ! ? "`.

## Commit messages

The commit is the durable record of *why*, and the only place history belongs.

- Conventional subject, imperative, <= 72 chars: `type(scope): summary`. The
  scope is a **single token**: `fix(matrixEditor)`, never `fix(matrix editor)`.
- Blank line, then a body wrapped at **80 columns** with real newlines.
- The body carries the **evidence**: the command that ran, its output and its
  exit code, not "should work". A rebaseline body names the upstream SHA and
  root-causes each direction of the change.
- Say what changed and why. The what-it-replaced belongs here, never in a doc or
  a comment.
- **No `Co-Authored-By` or generated-by trailers** in this repo.
- **Never reference a `__DEV/` path** - that tree is gitignored, so the reference
  is dead for every reader but its author.
- A commit that changes a number a doc pins changes the doc too, in the same
  commit.

## The gates

`bash scripts/test/run-docs-lint.sh` (CI lane: Docs Lint) fails on:

1. a dead internal link, resolved relative to the linking file's own directory,
2. a backticked `scripts/...` or `.github/...` path named in prose that does not
   exist - a bare filename like `run-smoke.sh` is **not** checked; write the path
   if you want the gate to hold it,
3. a baseline entry count quoted as `` `<name>-baseline.txt` (N) `` that
   disagrees with the file,
4. a non-ASCII byte in a tracked doc,
5. a tracked doc citing a path under `__DEV/`,
6. a missing `AGENTS.md` or `CLAUDE.md`, or a `CLAUDE.md` whose `@AGENTS.md`
   import is backticked, fenced or gone - Claude Code reads `CLAUDE.md`, never
   `AGENTS.md`, so that one line carries the whole contract,
7. an upstream-tracking page (`00` to `03`) with no **audit basis**, or one
   whose basis does not parse.

It needs no upstream clone and no toolchain, so it runs in seconds on every push.
Nothing gates a commit message.

**No gate can tell you a sentence is false.** The invented `toReal` rationale
parsed, linked, named no dead path, and pinned no number - and was fiction for
three weeks. No grep finds that; only reading does. The gate buys the mechanical
half so review can spend its attention on the half that needs a reader.

That is the failure mode to write against: prose here is accurate when written
and rots where the thing under it moves - especially upstream, which moves
without asking. Every sentence is a claim with a shelf life, so prefer the claim
that stays true: name the owner and the invariant, cite the file, and point at
the command for the number.
