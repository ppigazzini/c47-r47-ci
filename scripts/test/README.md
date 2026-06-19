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
- `run-leakscan.sh`: build the instrumented `testSuite`, run `--leakscan`
  and `--keyscan`, gate on any pool/GMP delta.
- per-test pool/GMP attribution in the suite.
- `run-coverage.sh`: coverage over the suite and the key-sequence driver.
- `run-fuzz.sh`: a libFuzzer harness over a parser entry point.
- breadth lanes (curated Valgrind suppressions, MemorySanitizer, static
  analysis, `-Werror` hardening warnings).
