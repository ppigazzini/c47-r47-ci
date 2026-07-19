# c43 Developer Documentation

## Overview

This repository is the **CI and test harness for upstream c43**. The product it
builds is **C47**, a high-precision RPN scientific calculator for the
SwissMicros DM42 family, descended from WP43. The repository is named `c43`; the
application is called C47.

The product source is not here. It lives upstream on GitLab at
<https://gitlab.com/rpncalculators/c43>, and every lane in this repo resolves
that upstream commit at runtime, clones it, and builds it. This documentation
therefore covers two things at once: **how C47 is built** so you can navigate
and debug it, and **how this harness drives it**.

The repository holds three things:

- **The lane scripts** - `scripts/test/` is the single source of truth for every
  test lane. A script runs unchanged on a maintainer's machine, so a CI failure
  is reproducible locally. One exception: the coverage lane's gates are set in
  its workflow, not its script - see [05-ci.md](05-ci.md).
- **The workflows** - `.github/workflows/` are thin callers that install a
  toolchain and invoke a script. Build and package lanes for Linux, macOS and
  Windows; analysis lanes for leaks, memory attribution, coverage, fuzzing,
  Valgrind, cppcheck and hardening warnings.
- **This documentation.**

## Documents

| Document | Audience | Description |
|---|---|---|
| [00-architecture.md](00-architecture.md) | All contributors | What C47 is: the god header, the item table, the HAL, and the measured dependency graph. Sections 1-8 are fact; 9-11 are assessment and an **unadopted** proposal |
| [01-codebase.md](01-codebase.md) | All contributors | The source tree: every module, the register file and memory model, the calculator's state, control flow from a key press to a screen |
| [02-build.md](02-build.md) | All contributors | The `make` targets, the Meson graph, the generators, cross-compilation, packaging and the upstream CI surface |
| [03-testing.md](03-testing.md) | All contributors | The behavioural corpus, the three drivers (testSuite, t47, GTK under xvfb), and the rules for writing a test that actually tests |
| [04-debugging.md](04-debugging.md) | Anyone chasing a bug | The detectors: pool and GMP leak scanning, the pool canary, coverage, fuzzing, Valgrind - and the false-pass catalogue |
| [05-ci.md](05-ci.md) | Harness contributors | The lane contract, the workflow-to-script mapping, baselines and how to add a lane |
| [06-references.md](06-references.md) | All developers | Upstream c43, GitHub Actions, Meson, make, Clang and shell references |
| [07-writing.md](07-writing.md) | Anyone writing a doc, a comment or a commit | One set of rules for all three, then what is specific to each: the doc set and hot vs cold pages, code comments, commit messages, and what the docs gate does and does not check |

For the agent and contributor ground rules, see [AGENTS.md](../AGENTS.md). For
what each lane script does in detail, see
[scripts/test/README.md](../scripts/test/README.md), which owns that subject.

## Quick start

The harness clones upstream itself. To work on the product directly:

```bash
git clone https://gitlab.com/rpncalculators/c43.git
cd c43

make simc47 t47     # the GTK simulator (./c47) and the scripted one (./t47)
make test           # the behavioural corpus; passes clean
make docs           # doxygen + sphinx

./t47 --reset --exec 'nim 2; nim 3; item 99; puts "X=[reg X]"'
```

Run a CI lane the way CI runs it:

```bash
bash scripts/test/run-smoke.sh
# log: ${HARNESS_WORK:-${RUNNER_TEMP:-/tmp}/c43-test-harness}/logs/smoke.log
```

`make test` passes clean, so any failure is a regression rather than a baseline
to compare against. Read the summary the run prints; the count moves with
upstream, so do not trust one written down here.
[03-testing.md](03-testing.md) owns this.

## Technology

| Layer | Technology |
|---|---|
| Product language | C, one library plus per-target adapters |
| Product build | top-level `Makefile` wrapping Meson and Ninja |
| Decimal maths | vendored decNumber / decQuad (`dep/decNumberICU`) |
| Big integers | GMP - the system library on hosts, a Meson wrap when cross-compiling |
| Simulator UI | GTK 3, plus a Jim/Tcl DSL (`t47`) for scripted control |
| Firmware targets | DM42 (DMCP, Cortex-M4) and DM42n/DM32 (DMCP5, Cortex-M33), `arm-none-eabi-gcc` |
| Tests | a declarative `.txt` corpus run by `src/testSuite` |
| Harness | POSIX shell scripts under `scripts/test/`, sourced from `lib/common.sh` |
| CI | GitHub Actions (this repo); upstream itself uses GitLab CI |

## Project layout

```
c47-r47-ci/
|-- AGENTS.md                 -- ground rules for agents and contributors
|-- CLAUDE.md                 -- one line: `@AGENTS.md` (Claude Code does not read AGENTS.md)
|-- docs/                    -- this documentation
|-- scripts/
|   `-- test/
|       |-- lib/common.sh    -- upstream resolve/sync, tooling overlay, xlsxio, ccache
|       |-- run-*.sh         -- one script per lane; the contract CI calls
|       |-- *-baseline.txt   -- the accepted-findings baselines each lane gates on
|       `-- tooling/         -- not-yet-upstream patches, suppressions, analysis helpers
|-- .github/workflows/       -- thin callers: toolchain setup + invoke a script
|-- README.md                -- what the workflows implement, and licensing
`-- LICENSE                  -- Blue Oak 1.0.0 for the harness code
```

The product tree, cloned at runtime by every lane, is laid out separately and is
mapped in [01-codebase.md](01-codebase.md).

## Licensing

Two surfaces, deliberately separate.

- The harness code here - workflows, scripts, docs - is under the Blue Oak Model
  License 1.0.0 in [LICENSE](../LICENSE).
- Simulator artifacts produced by these workflows are copies of upstream c43
  program material and remain under the **GNU GPL v3** shipped by c43 in its
  root `COPYING`, not under this repo's licence. The package lanes copy upstream
  `COPYING` and write a `SOURCE` provenance manifest into every artifact.
