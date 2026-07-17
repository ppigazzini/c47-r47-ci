# AGENT.md

Instructions for AI agents and new contributors working in this repository.
Read this before touching anything. It is short on purpose; the detail lives in
[docs/](docs/00-README.md).

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
   CI behaviour and product facts. When a local note and upstream disagree,
   upstream wins. Verify against a live clone, not memory.
2. **`__DEV/` is gitignored and maintainer-only.** It holds planning notes and
   working reports. Never commit it, never cite it from a tracked file, and
   never assume a reader can see it. Tracked documentation lives in `docs/`.
3. **ASCII by default** in tracked docs. No em dashes, no smart quotes.
4. **Conventional commits.** `type(scope): summary`, body wrapped at 80
   columns, imperative mood, no historical narration, no meta commentary about
   the process that produced the change.
5. **Never add a `Co-Authored-By` trailer** to a commit in this repo.
6. **Do not run destructive git commands** unless asked. In particular
   `git stash drop`, `git reflog expire`, `git gc --prune` and force-pushes.

## Read this first

| you want to | read |
|---|---|
| understand what C47 is and how it is put together | [docs/01-architecture.md](docs/01-architecture.md) - Sections 1-8 only; 9-11 are an unadopted proposal |
| find your way around the c43 source tree | [docs/02-codebase.md](docs/02-codebase.md) |
| build the simulator or the firmware | [docs/03-build.md](docs/03-build.md) |
| write or run a test | [docs/04-testing.md](docs/04-testing.md) |
| hunt a memory bug, a leak or a crash | [docs/05-debugging.md](docs/05-debugging.md) |
| understand or add a CI lane | [docs/06-ci.md](docs/06-ci.md) |
| find an authoritative external reference | [docs/07-references.md](docs/07-references.md) |

## The short version of the workflow

```bash
# get the product
git clone https://gitlab.com/rpncalculators/c43.git
cd c43

# build the GTK simulator and the scripted one
make simc47 t47        # -> ./c47 and ./t47

# run the behavioural corpus (this is "the tests")
make test              # 12065 pass / 6 fail on a healthy tree

# drive the calculator headlessly
./t47 --reset --exec 'nim 2; nim 3; item 99; puts "X=[reg X]"'
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

[docs/05-debugging.md](docs/05-debugging.md) carries the full false-pass
catalogue. Read it before trusting any lane result.

## Facts that surprise people

- **`make test` fails 6 tests on a healthy tree.** That is the baseline. Compare
  the failure *set*, not the count.
- **`src/generated/` in the c43 clone is gitignored** and populated by `make`'s
  `install -C` step, yet it sits on the include path *ahead of* the build dir.
  A stale copy silently shadows a freshly generated header.
- **The testSuite links GTK** even though it has no GUI, because the library
  defines GTK callbacks inside itself.
- **`./t47` is the `r47` build**, not a separate program, and its `press`
  command only exists when a window does. Keyboard-level tests need the GTK
  binary under `xvfb-run`, from the repo root.
- **The corpus tests computation only.** Nothing asserts the screen. A display
  regression will pass CI.

## Definition of done

- The claim is verified against a live upstream clone, or the inability to
  verify it is stated.
- Current upstream behaviour and any proposed future behaviour are not
  conflated.
- Upstream target names and artifact names are preserved exactly.
- Residual risks are explicit.
- Tracked docs are ASCII and do not reference `__DEV/`.
