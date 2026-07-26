# c43 Testing Harness (scripts/test)

This directory is the script-driven testing harness. The scripts are the single source of truth
for every test lane; the GitHub Actions workflows are thin callers that set up a
toolchain and invoke a script. The same script runs unchanged on a maintainer's
machine, so a CI failure is reproducible locally. The one exception is the
coverage lane: `run-coverage.sh` defaults to report-only while
`test-coverage.yml` sets `COVERAGE_MIN=45` and `SECTOR_GATE=1`, so export both
to reproduce a CI coverage failure.

## Layout

- `lib/skip127.sh` - runs a lane script and turns its exit **127** ("optional
  toolchain absent, gate did not run") into a passing step, announcing the skip on
  stdout and as a GitHub annotation. Only 127 is translated; every other non-zero
  status passes through. The five frama-c gates use it. It is a script, not inline
  YAML, so a maintainer sees the same line locally - and because a workflow must
  contain no logic that cannot be run locally.
- `lib/common.sh` - shared preamble sourced by every lane: upstream resolution
  and sync (with submodules), the optional test/* tooling overlay hook, the
  xlsxio static build, ccache configuration, job detection, and logging.
- `run-smoke.sh` - proves the call pattern end to end (resolve,
  sync, build-surface check, toolchain report, log). Does not build the
  simulator.
- `run-leakscan.sh` - builds the testSuite with the leak-scanner
  tooling overlaid, runs `--leakscan`/`--keyscan`, and gates on any pool/GMP leak
  or crash not in `leakscan-baseline.txt`.
- `run-testmem.sh` - runs the corpus under `--testmem` (per-test
  pool/GMP attribution) and gates on any growth case not in
  `testmem-baseline.txt`.
- `run-coverage.sh` - builds the testSuite with gcc coverage,
  exercises it (corpus, `--keyscan`, `--leakscan`), and publishes a gcovr
  coverage map, macro-sector coverage, direct function reachability, and the
  least-covered leak-prone modules. Report-only by default; set `COVERAGE_MIN`
  to gate on overall line coverage.
- `run-fuzz.sh` - builds the libFuzzer harness over
  `decodeOneStep` under clang (ASan gate, UBSan report) and runs a time-boxed
  campaign over a seed corpus, uploading any crash reproducer and the evolved
  corpus. Report-first; set `FUZZ_GATE=1` to fail on a finding.
- `run-warnings.sh` - rebuilds the testSuite with the OpenSSF
  hardening warning set and reports new warnings vs `warnings-baseline.txt`.
  Report-first; `WARN_GATE=1` to gate.
- `run-valgrind.sh` - runs the testSuite corpus under Valgrind
  memcheck with `tooling/valgrind.supp` and reports new c47 malloc-level sites
  vs `valgrind-baseline.txt`. Gating by default (`VALGRIND_GATE` defaults to 1);
  set `VALGRIND_GATE=0` to report without failing.
- `run-staticanalysis.sh` - runs cppcheck over the c47 sources (with confirmed
  false positives filtered by `tooling/cppcheck-suppressions.txt`) and reports
  new findings vs `cppcheck-baseline.txt`. Report-first; `ANALYSIS_GATE=1` to
  gate.
- `run-ui.sh` - the only lane that drives the keyboard. Builds the simulator
  (`make simc47 t47`) and runs every `ui/*.t47` through the **GTK** front end
  under `xvfb-run`, gating on each script's exit status. It runs `./c47`
  **without** `--headless` on purpose: `press` is the one DSL command that needs
  GTK, and `--headless` is GTK-less by design, so `t47` reports it as an unknown
  command. Needs no upstream patch. Reaches what no other lane can - softmenu
  decode, TAM entry and the matrix editor cursor.
- `ui/*.t47` - one self-checking DSL script per test, each exiting 0 on success
  and 1 with the failing check named. `ui/ij-preservation.t47` locks in upstream
  MR !1553: the matrix editor and the vector functions must leave the user's
  `I` and `J` alone.
- `run-nestcheck.sh` - probes self-referential engine nesting. Assembles the six
  `tooling/nestcheck/*.pgm` listings with `p47asm.py`, builds `simc47 t47`, and
  runs each headless under `timeout` **and `xvfb-run`**, classifying
  survived / crashed / hung. The legal depth-2 nest (`nested2`, root exactly 2) is
  the lane's control and must always survive. Report-only by default
  (`NESTCHECK_GATE=0`): upstream master still crashes on the SOLVE/SUM/PLOT
  probes, so the standing log count is the deliverable; `NESTCHECK_GATE=1` makes
  any non-survival a hard failure once the nesting budget merges.

  **`t47` needs a display even with no keyboard involved.** It is the same GTK
  binary as `c47` and calls `gtk_init` at `src/c47-gtk/c47-gtk.c:428`, before it
  parses its arguments, so on a machine with no display server it exits 1 with
  "cannot open display" - and `--headless` does not help, because the flag is read
  after `gtk_init` has already run. A desktop hides this: `DISPLAY`, or merely
  `XDG_RUNTIME_DIR` with a Wayland session, is enough for GTK to find a backend.
  A runner has neither, so the control failed on every CI run of this lane while
  passing everywhere else. Any lane that executes `c47`, `r47` or `t47` needs
  `xvfb-run` and the `xvfb` package, not just the ones that press keys.
- `run-stackprof.sh` - the only lane that builds firmware, and the only one that
  compares platforms. Profiles every DM42 feature package, the DM42n and the host
  simulator with one instrument, reporting how much C stack one nested engine
  evaluation costs against the stack that platform actually has: 2,472 bytes on
  the DM42, which one level already fills, against the host thread's 8 MiB. It
  also prints the compile-time limits matrix, where the load-bearing line is that
  **the simulator carries the new hardware's pool**, so a DM42 pool failure is not
  reproducible on it. Report-only for the per-level ceilings in
  `stackprof-baseline.txt` (`STACKPROF_GATE=1` to gate); the calibration against
  `gcc -fstack-usage` is hard either way when it finds an under-report, because a
  bound below the real frame permits the overflow it was meant to stop. A DMCP
  package that no longer fits in flash is reported, not fatal. It is the one lane
  that deliberately disables ccache: `-fstack-usage` writes a second output file
  per object that a cache hit would not replay.
- `tooling/stackprof.py` - the call-graph stack profiler the lane runs, for Thumb
  and x86-64, with the instruction set detected from the disassembly. Keys
  functions by address, not name (three GMP statics share one inside a single
  DM42 ELF); follows tail calls and the handler edges every `fn*` dispatch wrapper
  needs - a `.word` on Thumb, a rip-relative `lea` on x86-64 - without which
  `fnSin` scores 0 B; reports a recursion cycle as unbounded rather than cutting
  its back edge and printing a finite number. `--chain` sums a named call chain
  and fails if a link is not really an edge; `--cut` drops the recursion edge on
  purpose and says so; `--su-dir` calibrates every frame against
  `gcc -fstack-usage`, which needs a **no-LTO** build because LTO suppresses
  `.su` output entirely. Run it standalone on any ELF, firmware or host.
- `tooling/platform-limits.py` - the compile-time limits matrix. Compiles a
  generated probe against upstream's own `defines.h` under each platform's macros
  and tabulates what came back, flagging every value that differs between
  platforms. Integer constants only: every column is evaluated by the host
  compiler, so a limit derived from `sizeof` of a target type is refused rather
  than answered wrongly.
- `tooling/dmcp-stackband.py` - reads the C-stack band out of a shipped DMCP
  firmware image: initial MSP from the vector table, floor from the highest
  address firmware code loads as fixed data. Manual, not a lane - it needs a
  vendor image CI should not fetch. Re-run it when SwissMicros ships firmware;
  the constants in `run-stackprof.sh` and `docs/10-memory.md` are its output.
- `tooling/leakscan.patch` - the leak-scanner tooling (`--leakscan`, `--keyscan`,
  `--testmem`) carried off the `test/ram-pool-leak-scanner` branch, applied by the leak, memory and coverage lanes.
- `tooling/fuzz-decode.patch` + `tooling/fuzz-decode-seeds/` +
  `tooling/fuzz-decode.dict` - the libFuzzer harness over `decodeOneStep`
  carried off the `test/fuzz-decode-harness` branch, with its seed corpus and
  dictionary, applied by the fuzz lane.
- `tooling/coverage-sectors.py` - summarizes gcovr JSON by macro sector so the
  coverage lane reports CLI-relevant gaps instead of only a global percentage.
- `tooling/coverage-patch-audit.py` - audits a carried coverage-corpus patch,
  failing fast if a newly added corpus file is not also wired into
  `testSuiteList.txt`. The corpus itself merged upstream on 2026-07-09 (MR !1487),
  so `coverage.patch` is retired and the coverage lane no longer overlays it; this
  audit is retained for any future carried corpus patch.
- `tooling/p47asm.py` + `tooling/nestcheck/*.pgm` - a `.p47` assembler that turns
  a mnemonic listing into the calculator's byte-code program file, reading opcode
  numbers from the resolved clone's `src/c47/items.h` so it follows upstream
  renumbering. `--selftest` checks the encoder against byte streams executed
  against upstream, so a drifted encoding fails loudly instead of emitting
  plausible garbage. Used by `run-nestcheck.sh`; run standalone to craft any
  program repro without hand-counting bytes.
- `tooling/function-reachability.py` - summarizes the effective testSuite
  `funcTestNoParam[]` whitelist against c47 `LAST_ITEM`, so the coverage lane
  reports how much of the catalog is directly callable from corpus tests.
- `tooling/valgrind.supp` - curated Valgrind suppressions (GTK/GLib/GMP noise)
  used by the Valgrind lane.
- `tooling/cppcheck-suppressions.txt` - confirmed cppcheck false positives
  (GMP-init `uninitvar`, the `verifySqrtMatrix` contract) filtered by the
  static-analysis lane so a real finding stands out.

## Python in this directory

The helpers under `tooling/` are the repo's only Python. `pyproject.toml` at the
root configures ruff, ruff-format and ty for them; there is no package to build.
`requires-python` is **>= 3.14**, and the three workflows that invoke a helper
(`test-stackprof.yml`, `test-nestcheck.yml`, `test-coverage.yml`) pin the
interpreter to match, because the runner image ships an older `python3` and a
declared floor nothing enforces is a floor that breaks in CI only.

```sh
uv sync                      # .venv with ruff, ty, pre-commit and mpmath
pre-commit install           # once
pre-commit run --all-files   # hygiene, ruff, ruff-format, ty, run-docs-lint.sh
```

`uv.lock` is tracked so a lint result is reproducible; `.venv/` is not. `mpmath`
is in the dev group because `numeric-vectors.py` genuinely needs it, not as lint
scaffolding.

Two rules the config encodes, both because the default fought this repo:

- **`line-length = 170`, not ruff's 88.** [docs/07-writing.md](../../docs/07-writing.md)
  sets the comment wrap at 160-170 on purpose. A narrower setting does not just
  warn, it makes `ruff format` break correct code into worse shapes.
- **`end-of-file-fixer` and `trailing-whitespace` skip every file whose bytes are
  an input** - `.patch`, `.dict`, `.pgm`, `.cfg` and the fuzz seed corpora. A
  hunk header counts lines, so a whitespace edit makes a patch fail to apply.

`ruff format` is a formatter, so it cannot change behaviour - but two helpers
generate byte-exact fixtures (`numeric-vectors.py` writes a corpus block,
`p47asm.py` writes program bytes). Diff their output before and after touching
them, and run `p47asm.py --selftest`; that is cheaper than discovering a
reformatted f-string changed a fixture.

## Contract for new lanes

A lane script:

0. and one deviation worth naming: `run-stackprof.sh` skips
   `harness_configure_ccache` and exports `CCACHE_DISABLE=1` instead, because
   `-fstack-usage` emits a per-object `.su` file a cache hit does not replay,
   and an empty `.su` tree would make its self-check vacuous rather than loud;
1. sources `lib/common.sh`;
2. uses `harness_resolve_commit` and `harness_sync_upstream` to obtain the
   upstream tree at the resolved commit;
3. optionally calls `harness_overlay_tooling` to overlay not-yet-upstream tooling
   carried on a `test/*` branch off upstream `master` (e.g. the `--leakscan` /
   `--keyscan` scanners on `test/ram-pool-leak-scanner`);
4. calls `harness_setup_xlsxio` and `harness_configure_ccache` before building;
5. writes its output under `$LOG_DIR` for the CI upload step.

## Configuration (environment overrides)

`UPSTREAM_URL`, `UPSTREAM_REF`, `UPSTREAM_COMMIT` (pin), `XLSXIO_URL`,
`XLSXIO_COMMIT`, `HARNESS_WORK`, `UPSTREAM_DIR`, `XLSXIO_PREFIX`, `CCACHE_DIR`,
`LOG_DIR`. Defaults are set in `lib/common.sh`.

## Run locally

```sh
bash scripts/test/run-smoke.sh
# log: ${HARNESS_WORK:-/tmp/c43-test-harness}/logs/smoke.log
```

## Roadmap

- The smoke lane: `run-smoke.sh` + `test-harness-smoke.yml`. Done.
- `run-leakscan.sh` + `test-leakscan.yml`: pool/GMP leak gate. Done.
- `run-testmem.sh` + `test-testmem.yml`: per-test pool/GMP attribution. Done.
- `run-coverage.sh` + `test-coverage.yml`: coverage map over the suite,
  `--keyscan` and `--leakscan`, with macro-sector and direct-reachability
  reporting. Done (baseline 37.5% c47 line coverage before the expanded coverage
  corpus).
- `run-fuzz.sh` + `test-fuzz.yml`: libFuzzer over `decodeOneStep`. Done
  (the campaign immediately found a real decoder stack-buffer-overflow).
- breadth lanes: `run-warnings.sh` (OpenSSF hardening warnings, 294
  baselined), `run-valgrind.sh` (memcheck + suppressions, clean baseline),
  `run-staticanalysis.sh` (cppcheck, 22 baselined after filtering confirmed
  false positives) with their `test-*.yml`
  callers. Done. MSan (needs an instrumented libc/gmp) and clang-tidy (needs an
  upstream `.clang-tidy`) are documented deferrals.
- breadth lanes (curated Valgrind suppressions, MemorySanitizer, static
  analysis, `-Werror` hardening warnings).
- `run-stackprof.sh` + `test-stackprof.yml`: per-platform memory limits and
  C-stack profile over all four DM42 packages, the DM42n and the host simulator,
  calibrated against `gcc -fstack-usage` once per instruction set. Done. Two open
  follow-ups: a **dynamic high-water measurement** - paint the band at boot, run
  the corpus, read back how far the stack got, the only method that also catches
  GMP's `alloca` temporaries - and **macOS/Windows simulator frames**, which need
  a runner of each and would answer whether the host divergence is a Linux
  artifact or general.
