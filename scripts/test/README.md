# c43 Testing Harness (scripts/test)

This directory is the script-driven testing harness. The scripts are the single source of truth
for every test lane; the GitHub Actions workflows are thin callers that set up a
toolchain and invoke a script. The same script runs unchanged on a maintainer's
machine, so a CI failure is reproducible locally.

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
  coverage map plus the least-covered leak-prone modules. Report-only by
  default; set `COVERAGE_MIN` to gate on overall line coverage.
- `tooling/leakscan.patch` - the leak-scanner tooling (`--leakscan`, `--keyscan`,
  `--testmem`) carried off the `test/ram-pool-leak-scanner` branch, applied by the leak and per-test lanes.

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
  `--keyscan` and `--leakscan`. Done (baseline 37.5% c47 line coverage).
- `run-fuzz.sh`: a libFuzzer harness over a parser entry point.
- breadth lanes (curated Valgrind suppressions, MemorySanitizer, static
  analysis, `-Werror` hardening warnings).
