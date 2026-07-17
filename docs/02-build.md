# Building c43

The `make` targets, the Meson graph underneath them, the generators, and how
each platform package is produced. The product source is not in this
repository; every target below is run inside a clone of upstream c43.

```bash
git clone https://gitlab.com/rpncalculators/c43.git && cd c43
```

## The contract

The top-level `Makefile` is the user-visible build contract. Meson and Ninja are
the machinery underneath it. Preserve the target spellings exactly - `make sim`,
`make test`, `make dist_linux`, `make dmcp5r47` - they are referenced by
upstream CI, by this repo's lanes, and by the wiki.

| target | build dir | produces |
|---|---|---|
| `sim` / `simc47` | `build.sim` | `./c47` |
| `simr47` | `build.sim` | `./r47` |
| `both` | `build.sim` | `./c47` and `./r47` |
| `t47` | `build.sim.t47` | `./t47` - a copy of the `r47` build, `-DT47` |
| `both_asan` | `build.sim` | both simulators with AddressSanitizer; verifies ASan actually linked and exits 1 if not |
| `test` | `build.sim` | runs the corpus; cleans first |
| `docs` | `build.sim` | doxygen + sphinx |
| `dist_linux` | `build.rel.debug` | `c47-linux.zip` |
| `dist_macos` | `build.rel` | `c47-macos.zip` |
| `dist_windows` | `build.rel` | `c47-windows.zip` |
| `dist_dmcp` | `build.dmcp.p<N>` | `c47-dmcp-pkg<N>.zip` (default package 4) |
| `dist_dmcp5` | `build.dmcp5` | `c47-dmcp5.zip` |
| `dist_dmcp5r47` | `build.dmcp5` | `r47-dmcp5.zip` |

Notes that cost time if you do not know them:

- **`make t47` alone resolves to `t47: simr47`**, so `./t47` is the R47 build.
- **`f=1` is the fast path** for firmware builds: without it the build dir is
  wiped and GMP is cross-compiled from scratch every time.
- **`dist_windows` clones the upstream wiki** at build time - a network
  dependency inside a build target.
- **The zip filenames never carry the release tag.** The tag is appended by the
  upstream CI upload job, not by `make`.
- **`make test` cleans first**, deliberately, to avoid ASan contamination.

## The generators, and the trap under them

See [01-codebase.md](01-codebase.md) Section 4 for the full generator DAG. The one
thing to internalise: `src/generated/` in the clone is **gitignored**, populated
by `make`'s `install -C` step rather than by ninja, and sits on the include path
**ahead of** the build directory. A stale copy silently shadows a freshly
generated header, producing errors that make no sense against a correct build
dir. Refresh it after any upstream constant or catalog change.


## The make targets in detail

From upstream `Makefile` / `BUILD.md`:

| Target | What it does |
|---|---|
| `make sim` | builds `c47` (GTK, `-DCALCMODEL=USER_C47`), copies to repo root, then `install -C`s 5 generated files into `src/generated/` (see hazard 22.7) |
| `make simc47` | pure alias for `sim` |
| `make simr47` | builds `r47` (`-DCALCMODEL=USER_R47`) |
| `make both` | `sim simr47` |
| `make t47` | **as a goal modifier** flips `BUILD_PC` to `build.sim.t47` (adds `-Dc_args="-DT47"`) and enables the `cp c47 t47` step. A **bare `make t47` builds the R47-based t47**. Use `make simc47 t47`. |
| `make test` | `clean` + build + run the corpus. Cleans first to avoid ASan contamination. |
| `make repeattest` | re-run without the clean (timing/stability); stamp-driven |
| `make test_asan` | the suite with `-Db_sanitize=address` |
| `make both_asan` | `c47`+`r47` with ASan, **with a guard that fails if the binary did not actually link the ASan runtime** (`ldd \| grep asan`) |
| `make testPgms` | builds and stages `res/testPgms/testPgms.bin` (see [03-testing.md](03-testing.md) Section 5) |
| `make docs` | needs `sphinx-build`, `doxygen`, `breathe-apidoc`; silently produces no target if any is missing |
| `make XVFB=xvfb-run dist_linux` | packaging; `XVFB` is an override variable, empty by default |

ASan is explicitly unsupported on Windows MinGW; the Makefile builds without it
there. The base setup line is:

```
meson setup build.sim --buildtype=custom -DRASPBERRY=`tools/onARaspberry` -DDECNUMBER_FASTMUL=true
```

## Meson test integration and sanitizer options

`src/testSuite/meson.build` registers a single Meson test, `testSuite`, run with
`tests/testSuiteList.txt`, **`workdir: meson.project_source_root()`** and an
**800 s timeout**, built `-DTESTSUITE_BUILD` (headless: no GTK GUI paths). So
`meson test` and any `-Db_sanitize` / `-Db_coverage` option apply to the whole
corpus.

The 800 s timeout has no headroom under ASan+UBSan: the lane was killed
mid-run (`testSuite TIMEOUT 800.02s killed by signal 15`) through the
distribution tests and looked like a hang. It was not. Use
`meson test -C "$build_dir" --print-errorlogs --timeout-multiplier 3`. Do **not**
use `--no-timeout` / `--timeout-multiplier 0` - a genuine hang would then burn
the whole job cap with no per-test signal.

Sanitizer build options: `-Db_sanitize=address` (and `address,undefined` in the
analysis lanes) with `-Dc_args` for extra flags. The analysis lanes add
`-fno-sanitize=alignment -fno-omit-frame-pointer`. Clang additionally needs
`-Dc_link_args="-fuse-ld=lld" -Db_lundef=false` (the c47-gtk targets force
`b_lto=true`; under Clang+LTO+ASan, ld.bfd discards the `asan.module_dtor`
comdat sections then errors on references to them, and `--no-undefined` is
incompatible with the Clang sanitizer runtime).

For the CI lanes that run these targets, see [05-ci.md](05-ci.md).
