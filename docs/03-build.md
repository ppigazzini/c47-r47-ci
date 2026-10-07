# Building c43

Audit basis: upstream `7f030deba57dd9df0e01bdf6ff395898131868dd`, 2026-10-07.

The `make` targets, the Meson graph underneath them, the generators, and how
each platform package is produced. The product source is not in this
repository; every target below is run inside a clone of upstream c43.

```bash
git clone https://gitlab.com/rpncalculators/c43.git && cd c43
```

## The contract

The top-level `Makefile` is the user-visible build contract. Meson and Ninja are
the machinery underneath it. Preserve the target spellings exactly: upstream's
`.gitlab-ci.yml` runs `test`, `docs` and the `dist_*` targets; upstream's
`BUILD.md` and `AGENTS.md` name `sim`, `simc47 t47`, `dmcp5r47`, `repeattest` and
`PKG=4 dmcp_pkg4`; this repo's lanes run `simc47 t47`, `both`, `test`, `docs` and
`dist_linux`/`dist_macos`/`dist_windows`.

| target | build dir | produces |
|---|---|---|
| `sim` / `simc47` | `build.sim` | `./c47` |
| `simr47` | `build.sim` | `./r47` |
| `both` | `build.sim` | `./c47` and `./r47` |
| `t47` | `build.sim.t47` | `./t47`, built `-DT47` - a copy of `./c47` with `make simc47 t47`, of `./r47` with a bare `make t47` |
| `both_asan` | `build.sim` | both simulators with AddressSanitizer; verifies ASan actually linked and exits 1 if not |
| `test` | `build.sim` | runs the corpus; cleans first |
| `docs` | `build.sim` | the code documentation, doxygen + sphinx (`docs/code/meson.build`) |
| `dist_linux` | `build.rel.debug` | `c47-linux.zip` |
| `dist_macos` | `build.rel` | `c47-macos.zip` |
| `dist_windows` | `build.rel` | `c47-windows.zip` |
| `dist_dmcp` | `build.dmcp.p<N>` | `c47-dmcp-pkg<N>.zip` (default package 4) |
| `dist_dmcpr47` | `build.dmcp.p<N>` | `r47-dmcp.zip` |
| `dist_dmcp5` | `build.dmcp5` | `c47-dmcp5.zip` |
| `dist_dmcp5r47` | `build.dmcp5` | `r47-dmcp5.zip` |
| `bench` | `build.sim.t47.bench` | `./t47bench`, then `tools/bench/benchreport.py` |

**A DMCP package is chosen by `PKG=<N>` or `DMCP_PACKAGE=<N>` on the make command
line.** `make PKG=<N> dmcp_pkg<N>` builds one package and
`make PKG=<N> dist_dmcp_pkg<N>` packages it. The per-package rules exist only
when `PKG` is set (`Makefile:276`, `:361`, `:365`); without it `make dmcp_pkg1`
prints `Nothing to be done` and exits 0, building nothing. `dmcp_pkgs_all` and
`dist_dmcp_pkgs_all` sweep 1 to 3, `dist_dmcp_pkgs_1_2` does 1 and 2 and
`dist_dmcp_pkgs_small` 2 and 3; each passes `PKG` itself. `DMCP_PACKAGE`
(`Makefile:24`, default 4) selects the package for `dmcp`, `dmcpr47` and
`dist_dmcp`, which delegates to `dist_dmcp_pkg$(DMCP_PACKAGE)`. Which packages
link is a memory question, not a build one - see [06-memory.md](06-memory.md).

What a package number selects is an `OPTION_*` profile in `src/c47/defines.h`,
and **it is reachable only from a DMCP build**. `Makefile:24` supplies the
default 4; meson forwards `-DDMCP_PACKAGE` only when `DMCPVERSION` is `dmcp`
(`meson.build:42-45`), and the ladder that reads it sits inside
`#if defined(DMCP_BUILD)`. So `meson setup build.sim -DDMCP_PACKAGE=1` is
accepted and changes no option, and no target in the table above builds a
shipping DM42 feature set on the host. Two consequences bite here rather than in
`06`: `make test` runs the simulator's profile whatever package you last built,
and a package number outside 1 to 4 - including none at all, the meson option's
default being empty - reaches no package block, though the block common to
packages 1-4 still applies, and builds a configuration nobody ships.
[00-architecture.md](00-architecture.md) s7 owns the measurement and what it
costs.

Notes that cost time if you do not know them:

- **`make t47` alone resolves to `t47: simr47`**, so `./t47` is the R47 build.
- **`f=1` is the fast path** for firmware builds: without it the build dir is
  wiped and GMP is cross-compiled from scratch every time.
- **`dist_windows` and every DMCP `dist_*` target clone the upstream wiki** at
  build time (`build.rel/wiki`, `Makefile:196-198`) - a network dependency inside
  a build target. `dist_linux` and `dist_macos` do not.
- **The zip filenames never carry the release tag.** The tag is appended by the
  upstream CI upload job, not by `make`.
- **`make test` cleans first**, deliberately, to avoid ASan contamination.
- **The DSL is conditional on the submodule.** `dep/jimtcl` is a submodule. In a
  git checkout, configure runs `git submodule update --init --recursive` itself
  (`meson.build:49`), so an empty `dep/jimtcl` comes from a source archive or an
  offline configure. The top-level `meson.build` then warns, declares an empty
  `t47_dep` and leaves `HAVE_T47_DSL` undefined; the build succeeds, and
  `--exec` and `--script` print `This build has no T47 DSL: dep/jimtcl was
  missing when the build was configured.` and exit 1 (`c47-gtk.c:560`, `:577`).
  Fetch the submodule, then reconfigure.

## The generators, and the trap under them

See [01-codebase.md](01-codebase.md) Section 4 for the full generator DAG. The one
thing to internalise: `src/generated/` in the clone is **gitignored**, populated
by `make`'s `install -C` step rather than by ninja, and sits on the include path
**ahead of** the build directory. A stale copy silently shadows a freshly
generated header, producing errors that make no sense against a correct build
dir. Refresh it after any upstream constant or catalog change.

The directory is one per clone and the build directories are one per
configuration, so what it shadows is not only an older header but **another
configuration's**: `make sim` installs the simulator's copies, and a firmware or
package build afterwards compiles against them. `make clean` removes them
(`Makefile:47`); do that between configurations, or build each in a clone of its
own.


## The make targets in detail

From upstream `Makefile` / `BUILD.md`:

| Target | What it does |
|---|---|
| `make sim` | builds `c47` (GTK, `-DCALCMODEL=USER_C47`), copies to repo root, then `install -C`s 5 generated files into `src/generated/` (see 05-debugging Section 12) |
| `make simc47` | pure alias for `sim` |
| `make simr47` | builds `r47` (`-DCALCMODEL=USER_R47`) |
| `make both` | `sim simr47` |
| `make t47` | **as a goal modifier** flips `BUILD_PC` to `build.sim.t47` (adds `-Dc_args="-DT47"`) and enables the `cp c47 t47` step. A **bare `make t47` builds the R47-based t47**. Use `make simc47 t47`. |
| `make test` | `clean` + build + `testPgms` + run the corpus. Cleans first to avoid ASan contamination. Prints the `NUMBER OF TESTS` line from `build.sim/meson-logs/testlog.txt` once `ninja test` passes (`Makefile:166`); on a failure the summary and the failing cases are in that log only |
| `make repeattest` | re-run without the clean (timing/stability); stamp-driven |
| `make test_asan` | the suite with `-Db_sanitize=address` |
| `make both_asan` | `c47`+`r47` with ASan, **with a guard that fails if the binary did not actually link the ASan runtime** - `otool -L` then `ldd`, so it holds on macOS and Linux alike (`Makefile:83`, `Makefile:91`) |
| `make testPgms` | builds `res/testPgms/testPgms.bin` and writes it over the tracked copy (see [04-testing.md](04-testing.md) Section 5); `test`, `repeattest` and `test_asan` do the same, and upstream `AGENTS.md` section 10 says when to commit it and when to restore it |
| `make docs` | the code documentation only; with `sphinx-build`, `doxygen` or `breathe-apidoc` missing, configure prints a message and defines no `docs` target. The owner's manual and the application notes build through `make -C docs/manual pdf` and the `docs/appnotes` Makefile (each has a `BUILD.md`), and `make -C docs release` copies the documents a `docs-` tag releases |
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

The 800 s timeout (`src/testSuite/meson.build`) has no headroom under
ASan+UBSan: a run can be killed mid-corpus
(`testSuite TIMEOUT 800.02s killed by signal 15`) and resemble a hang without
being one. Use `meson test -C "$build_dir" --print-errorlogs
--timeout-multiplier 3`. Do **not** use `--no-timeout` / `--timeout-multiplier 0`
- a genuine hang would then burn the whole job cap with no per-test signal.

Sanitizer build options: `-Db_sanitize=address` (and `address,undefined` in the
analysis lanes) with `-Dc_args` for extra flags. The analysis lanes add
`-fno-sanitize=alignment -fno-omit-frame-pointer`. Clang additionally needs
`-Dc_link_args="-fuse-ld=lld" -Db_lundef=false` (the c47-gtk targets force
`b_lto=true`; under Clang+LTO+ASan, ld.bfd discards the `asan.module_dtor`
comdat sections then errors on references to them, and `--no-undefined` is
incompatible with the Clang sanitizer runtime).

For the CI lanes that run these targets, see [07-ci.md](07-ci.md).
