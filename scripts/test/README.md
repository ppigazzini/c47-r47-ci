# c43 Testing Harness (scripts/test)

This directory is the script-driven testing harness. The scripts are the single source of truth
for every test lane; the GitHub Actions workflows are thin callers that set up a
toolchain and invoke a script. The same script runs unchanged on a maintainer's
machine, so a CI failure is reproducible locally. The one exception is the
coverage lane: `run-coverage.sh` defaults to report-only while
`test-coverage.yml` sets `COVERAGE_MIN=45` and `SECTOR_GATE=1`, so export both
to reproduce a CI coverage failure.

## Layout

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
- `tooling/function-reachability.py` - summarizes the effective testSuite
  `funcTestNoParam[]` whitelist against c47 `LAST_ITEM`, so the coverage lane
  reports how much of the catalog is directly callable from corpus tests.
- `tooling/valgrind.supp` - curated Valgrind suppressions (GTK/GLib/GMP noise)
  used by the Valgrind lane.
- `tooling/cppcheck-suppressions.txt` - confirmed cppcheck false positives
  (GMP-init `uninitvar`, the `verifySqrtMatrix` contract) filtered by the
  static-analysis lane so a real finding stands out.

## Contract for new lanes

A lane script:

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
