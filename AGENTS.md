# AGENTS.md

Instructions for AI agents and new contributors working in this repository.
Read this before touching anything. It is short on purpose: it is only what a
newcomer gets wrong *before* reading [docs/](docs/README.md), which is where the
detail lives.

**Docs are part of the change, not after it.** Each page in `docs/` is a live
claim about the thing it describes - and the ones marked hot in that page's own
table describe **upstream**, a tree that moves without a commit here. Change something a page claims, fix the
page in the SAME commit; sync upstream, re-read the pages that track it.
[docs/10-writing.md](docs/10-writing.md) carries the rules for everything this
repo writes for a reader - pages, code comments, corpus comments, commit
messages and merge request text alike - and maps every page to what it owns and
which run hot. Three of those land in upstream c43 and meet its review conditions
there; a t47 script in any of them names its commands, never `item <n>`. `bash scripts/test/run-docs-lint.sh`
catches a dead link, a dead cross-page section reference, a dead path, a stale
pinned count, a non-ASCII byte, a `__DEV/` citation, a broken `@AGENTS.md`
import, or an upstream-tracking page with no audit basis. It cannot tell you a sentence has become false, and an
audit basis is itself a sentence. That part is yours.

## What this repository is

This is the **CI and test harness for upstream c43**. It builds, tests and
debugs a product whose source lives somewhere else.

- The product is **C47**, an RPN scientific calculator for the SwissMicros DM42
  family. Its authoritative source is upstream c43 on GitLab:
  <https://gitlab.com/rpncalculators/c43>. The repository is named `c43`; the
  application it builds is called C47.
- **This repo contains no product code.** The workflows and scripts resolve
  upstream `master` at runtime, clone it, and build it.
- What is here: `.github/workflows/` (the CI lanes), `scripts/test/` (the lane
  scripts, which are the single source of truth for what each lane does), and
  `docs/`.

## What this repository is not

- Not a fork of c43. Never commit product code here.
- Not the place to fix a c43 bug. A fix goes to upstream c43 as a merge request.
  This repo may carry a not-yet-upstream tooling patch under
  `scripts/test/tooling/`, and that is the only exception.

## Non-negotiables

1. **Upstream c43 is the source of truth** for build targets, artifact names,
   CI behaviour and product facts, and its own `AGENTS.md` is the contract for
   anything this repo sends there. When a local note and upstream disagree,
   upstream wins. Verify against a live clone, not memory. The split is below,
   under [Two AGENTS.md files](#two-agentsmd-files).
2. **`__DEV/` is gitignored and maintainer-only.** It holds planning notes and
   working reports. Never commit it, never cite it from a tracked file, and
   never assume a reader can see it. Tracked documentation lives in `docs/`.
3. **ASCII by default** in tracked docs.
4. **Conventional commits**, carrying the evidence rather than "should work".
   [docs/10-writing.md](docs/10-writing.md) owns the format; do not restate it
   here.
5. **Never add a `Co-Authored-By` trailer** to a commit in this repo.
6. **Do not run destructive git commands** unless asked. In particular
   `git stash drop`, `git reflog expire`, `git gc --prune` and force-pushes.

## How to work here

The sections above are what this repo is. This is how to work in it; each line
is here because the other behaviour costs something measurable in this tree.

1. **Deliver what was asked, at the scope asked.** Make routine judgment calls
   yourself, and check in only where two readings of the request lead to
   materially different work. If the request looks wrong, say so in a sentence
   and build it anyway rather than quietly narrowing, widening or transforming
   it.
2. **Finish, or name what you did not finish.** Report completion only when
   every part is done. A part silently left out is the one failure no gate here
   catches: the lanes check the tree, never the request.
3. **Add nothing nobody asked for.** No abstraction for a one-time operation, no
   error handling for a case that cannot arise, no refactor riding along with a
   fix. A lane script is read by whoever is staring at a red run, and every
   extra line is one they have to rule out first.
4. **Delegate rarely, and never delegate verification.** A subagent
   re-establishes context, re-explores, reports back, and then you re-read the
   report. Hand off a wide multi-file investigation or two genuinely independent
   tracks; do not hand off a handful of tool calls. The verification discipline
   below is the part you run yourself - a second agent agreeing with you is not
   a negative control.
5. **Lead with the outcome.** First sentence: what happened, or what you found.
   Evidence after it. Between tool calls, write when you find something, change
   direction or hit a blocker, not to announce the next call.
6. **Correct only what changes a decision.** If an earlier statement would
   change the reader's code, conclusion or next step, fix it plainly and carry
   on. A slip that changes nothing gets fixed, not announced.

## Read this first

| you want to | read |
|---|---|
| understand what C47 is and how it is put together | [docs/00-architecture.md](docs/00-architecture.md) - Sections 1-9 are fact; 10-11 are assessment and 12 an unadopted proposal |
| find your way around the c43 source tree | [docs/01-codebase.md](docs/01-codebase.md) |
| identify the high-level module you are touching, and the literature to search for it | [docs/02-modules.md](docs/02-modules.md) |
| build the simulator or the firmware | [docs/03-build.md](docs/03-build.md) |
| write or run a test | [docs/04-testing.md](docs/04-testing.md) |
| hunt a memory bug, a leak or a crash | [docs/05-debugging.md](docs/05-debugging.md) |
| work out whether something fits in the firmware's memory | [docs/06-memory.md](docs/06-memory.md) |
| understand or add a CI lane | [docs/07-ci.md](docs/07-ci.md) |
| find an authoritative external reference | [docs/08-references.md](docs/08-references.md) |
| look up a term, or check which tier of vocabulary it belongs to | [docs/09-glossary.md](docs/09-glossary.md) |
| write a doc, a code comment, a corpus comment, a commit message or an MR body | [docs/10-writing.md](docs/10-writing.md) |

## Two AGENTS.md files

Upstream c43 carries an `AGENTS.md` of its own, `C47/R47 rules for contributed
code`, and it opens by stating that code ignoring it is rejected without review.
That file governs **what this repo sends to c43**: product code, code comments,
corpus comments, commit messages on a c43 branch, merge request text, and how an
MR's commits move while it is under review. This
file governs **what stays here**: the lanes, the scripts, `docs/`, and how work
in this repository is carried out. Where both speak, upstream wins, and the way
to comply is to read upstream's file rather than a summary of it here - a copy
drifts the moment upstream edits it, and a stale copy of a rejection rule is
worse than none.

The sections that catch this repo most often:

| upstream section | what it binds |
|---|---|
| 6, and 11 item 11 | a new item behind an `OPTION_` macro, and the MR's package 4 flash figure with the option on and off (`make PKG=4 dmcp_pkg4`) |
| 8.1, 8.2 | what a code comment states, and its 160-to-170 column layout |
| 8.3 | words refused in comments, commit notes and merge request text, with the replacement for each |
| 9 | `res/SCRIPTS/cli_automation_examples.txt` read in full before any `t47` or `c47` run, freshly each session |
| 10 | what an MR states (which claims are measured and which are reasoned), and the `res/testPgms/testPgms.bin` that `make test` writes over the tracked copy |
| 12 | a review correction pushed as `git commit --fixup=<sha>`, no force-push while a review is open, `git rebase --autosquash <base>` before the merge |

Section 11 lists what is rejected without review, and item 10 is a refused word
in a comment or in merge request text, so section 8.3 is a gate rather than a
preference. `scripts/test/run-upstream-contract.sh` reads section 8.3's word
list out of a live clone and checks a drafted merge request body, or the commit
messages on a c43 branch, against it.

Reconciled against upstream `7f030deba`. Upstream's file carries no version
marker, so re-read it when a sync moves master and record the commit here.

## This file, and CLAUDE.md

`AGENTS.md` is the cross-tool convention (stewarded by the Agentic AI Foundation
under the Linux Foundation; read natively by Codex, Cursor, Aider, Jules and
others). **Claude Code does not read it** - it reads `CLAUDE.md` only. The root
`CLAUDE.md` is therefore one line, the `@AGENTS.md` import Anthropic documents
for exactly this case; the sibling zfish repo uses the same shape. Prose beside
that line is a second copy of this file that nothing updates, so there is none:
edit this file, never that one. A symlink would also work but breaks on Windows
without Developer Mode, and this repo ships Windows packages.

## The short version of the workflow

```bash
# get the product
git clone https://gitlab.com/rpncalculators/c43.git
cd c43

# build the GTK simulator and the scripted one
make simc47 t47        # -> ./c47 and ./t47

# run the behavioural corpus (this is "the tests")
make test              # builds the testPgms fixture, then runs the corpus; passes clean

# drive the calculator headlessly
./t47 --reset --exec 'nim 2; nim 3; xeq +; puts "X=[reg X]"'      # -> X=5
```

Run a CI lane the way CI runs it - the script is the contract, the workflow is a
thin caller:

```bash
bash scripts/test/run-smoke.sh
```

One exception, and it will mislead you: **the coverage lane's gates live in the
workflow, not the script.** `run-coverage.sh` defaults to report-only, while
`test-coverage.yml` sets `COVERAGE_MIN=45` and `SECTOR_GATE=1`. To reproduce a
CI coverage failure locally you must export both. Every other lane reproduces
from the bare script; `VALGRIND_GATE` is the only knob whose script default is
already on.

## The verification discipline

This project has burned real time on results that were confidently wrong. The
rules below are not style; each one exists because it failed.

1. **A stale build is not evidence.** After changing a branch or a source file,
   `touch` the owning translation unit or wipe the build dir, and rebuild.
   `git stash` does **not** revert a commit - if the work is committed, stashing
   changes nothing and your "baseline" is your own branch.
2. **Print the resolved commit in the same command that prints the reading.**
   A clean result may mean the fix is applied, not that the bug is absent.
3. **A negative control is mandatory.** Show the check failing on the unfixed
   tree. A gate that has never fired is not a gate.
4. **Never test the exit code of the last command in a pipe.**
   `grep ... | head` returns `head`'s status. `diff <(a) <(b)` over two missing
   files succeeds. Both have silently passed broken things here.
5. **Choose sentinel values adversarially.** An integer sentinel round-trips
   through code that silently destroys fractions, wide values and types. Probe
   `0.35` and `99999`, not just `7`.
6. **Retract what you cannot prove.** Say which claims are measured, which are
   read from the source, and which are inferred. Explicit uncertainty beats
   plausible filler.
7. **Hostile-audit every candidate fix before you commit it** - attack the root
   cause, the repro (must fire without the fix), the blast radius, and the same
   class elsewhere. A patch you wrote is a suspect, not a solution. Full rule in
   [docs/04-testing.md](docs/04-testing.md) section 7.2.

[docs/05-debugging.md](docs/05-debugging.md) carries the full false-pass
catalogue. Read it before trusting any lane result.

## Facts that surprise people

- **`make test` passes clean**, so any failure is a real regression rather than a
  known baseline to compare against. Read the summary the run prints; the count
  moves with upstream, so do not trust one written down here.
- **A green `make test` is not evidence about the DM42 firmware.** The host build
  keeps `OPTION_CUBIC_159` and `OPTION_EIGEN_159`, defined at the top of
  `src/c47/defines.h`, so it compiles the 159-digit cubic and eigenvalue solvers.
  Every DM42 package undefines both in the block common to packages 1-4 and runs
  the 75-digit twins, and no corpus case reaches them; only package 3 carries
  `OPTION_EIGEN` at all. Passing the package number to a host build does not fix
  that: the `OPTION_*` profile lives inside `#if defined(DMCP_BUILD)`, so
  `-DDMCP_PACKAGE=n` on a `PC_BUILD` changes one macro and no option
  ([docs/00-architecture.md](docs/00-architecture.md) s7.2). That is one row of
  a larger table: every check in this repo compares the calculator against
  *something*, three of them compare it against nothing while looking green, and
  [docs/04-testing.md](docs/04-testing.md) Section 8 says which is which.
- **`src/generated/` in the c43 clone is gitignored** and populated by `make`'s
  `install -C` step, yet it sits on the include path *ahead of* the build dir.
  A stale copy silently shadows a freshly generated header.
- **The testSuite links GTK** even though it has no GUI, because the library
  defines GTK callbacks inside itself.
- **`c47` and `t47` are one binary, byte for byte** - the front end is picked
  from `argv[0]`, with `t47` forcing headless. Build both with `make simc47 t47`
  exactly: a bare `make t47` builds the R47-based t47 instead. **`press` works in
  every front end**, headless included; what still needs a display is `gtk_init`, which the binary calls unconditionally, so a
  keyboard test on a machine with no X server runs under `xvfb-run` whichever
  front end it uses. Run it **from the repo root** on Linux - the chdir that
  would lift that is `__APPLE__`-only (`c47-gtk.c:76`). Upstream's
  `res/SCRIPTS/cli_automation_examples.txt` is the DSL's own reference, and
  upstream's `AGENTS.md` section 9 makes reading it in full a precondition of
  using `t47` or `c47` at all, freshly at the start of every session rather than
  recalled from the last one.
- **Two corpus files assert pixels, and only for plots.** `graphs_cov.txt` and
  `nested_cov.txt` render through `SNAP` and pin a SHA-256 of each bitmap
  (`fnHashBmpCov`), so a change to the grapher, the fonts or the blitter fails
  them. Other files assert display **text**, not pixels: the `drm_*_cov` files,
  `accuracy_fix_cov.txt` and `rm_iter_cov.txt` compare the string the X line, a
  stack line, a matrix editor cell or the printer stream carries (`DSX`, `DLX`,
  `DVX`-`DVT`, `MEC`, `PRX`, in `checkExpectedOutParameter`). Glyph placement,
  the status bar, the softmenus and every other pixel carry no assertion, and a
  regression there passes CI.
- **The lanes share one upstream tree** at `${RUNNER_TEMP:-/tmp}/c43-test-harness` and each wipes
  it on entry, so two run at once will corrupt each other and the failure surfaces
  as an unrelated build error. Give each its own `HARNESS_WORK`. The Valgrind lane
  is the slowest by far, and its run time moves with upstream by an order of
  magnitude; read it from `gh run list --workflow="Valgrind Memcheck"` before
  calling a run hung.
  See [docs/07-ci.md](docs/07-ci.md).
- **The simulator does not have the DM42's memory model, so it cannot reproduce
  a DM42 memory failure.** It is compiled with the *new* hardware's pool - 256 KiB
  against the DM42's 64 KiB, and 200 free regions against 50 - and its C stack is
  the host thread's 8 MiB. Recursion depth, pool exhaustion and any
  multi-kilobyte local are hardware questions a host build answers wrongly, not
  slowly. `bash scripts/test/run-stackprof.sh` profiles every platform with one
  instrument; see [docs/06-memory.md](docs/06-memory.md).
- **Which stack a DM42 program runs on is read two ways, and the readings
  disagree.** DMCP documents neither; both come out of the firmware image. This
  repo's `tooling/dmcp-stackband.py` finds SVCall and PendSV writing PSP, so
  thread mode runs on a task stack out of the 90,104-byte arena that also holds
  C47's 64 KiB pool and every GMP long integer - at most **24,568 bytes** for the
  stack and everything else - and the band below the initial MSP is the handler
  and boot stack. Upstream's `tools/pgemu/MEASUREMENTS.md` reads the same image
  as an **8,104-byte** stack from the initial MSP down to the arena. Upstream's
  hardware run bounds both: the `PLOT_NESTING_ALLOWED` comment in
  `src/c47/defines.h` records INT inside INT (7,684 bytes) surviving on the DM42
  and a plot with an integral inside it (12,020 bytes on the DM42n) hanging,
  which upstream reads as the overrun. Name the reading any DM42 stack figure
  comes from; neither one alone is "the stack a program gets".
- **The DM42 build has four feature packages, and which of them link moves with
  the tree and the compiler.** `DMCP_PACKAGE` trades functions for flash, so each
  package has its own set of built code; upstream's pipeline builds package 4
  only (`make dist_dmcp`). With Arm's 14.2.Rel1 binary standing in for the
  `arm-none-eabi-gcc` 14.2.1 that upstream's `ubuntu:25.10` CI installs, upstream
  `7f030deba` overflows the 704 KiB FLASH region in packages 1, 2 and 3 (by 1,536,
  512 and 1,232 bytes) and links package 4 with 27,472 bytes left; the same
  binary linked all four at `ad322d6a3`, where Ubuntu 24.04's 13.2.1 - the
  compiler this repo's stackprof lane uses - already overflowed 1, 2 and 3.
  Measure the package you mean with `make PKG=n dmcp_pkgn` under the compiler
  you care about, at the commit you care about, not "the DM42".
- **A lane failing does not mean this repo changed.** Every lane resolves upstream
  `master` at runtime, so an upstream commit breaks CI here with no commit here.
  Pin with `UPSTREAM_COMMIT` to tell the two apart.

## Definition of done

- The claim is verified against a live upstream clone, or the inability to
  verify it is stated.
- Current upstream behaviour and any proposed future behaviour are not
  conflated.
- Upstream target names and artifact names are preserved exactly.
- Residual risks are explicit.
- Tracked docs are ASCII and do not reference `__DEV/`.
- Every part of the request is done, or the part that is not is named.
- The report opens with the outcome and runs as long as the evidence, no
  longer.
