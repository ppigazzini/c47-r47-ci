# References

Authoritative sources. Prefer these over secondary summaries, and prefer
upstream c43 files over any note in this repository when the two disagree.

## Upstream c43 - the product

- Repository: <https://gitlab.com/rpncalculators/c43>
- `README.md` - product identity and the naming history (WP43S -> WP43 -> WP43C -> C43 -> C47)
- `BUILD.md` - the public `make` targets
- `Makefile` - the build contract: target names, build dirs, dist names, DMCP package variables
- `meson.build`, `meson_options.txt`, `src/c47-dmcp*/cross_arm_gcc.build` - the build graph and cross files
- `.gitlab-ci.yml` - upstream's own CI: stages, artifacts, runner tags, release rules
- `docs/appnotes/` - first-party application notes, including the `.d47` file-format spec
- Community wiki build instructions: <https://gitlab.com/h2x/c47-wiki/-/wikis/Build-instructions>
- Project wiki: <https://gitlab.com/rpncalculators/c43/-/wikis/home>

Upstream is a GitLab project and uses GitLab CI. The GitHub Actions lanes in
this repository are additional, not a replacement.

## Build tooling

- GNU make manual: <https://www.gnu.org/software/make/manual/>
- Meson built-in options: <https://mesonbuild.com/Builtin-options.html>
- Meson cross compilation: <https://mesonbuild.com/Cross-compilation.html>
- POSIX shell command language: <https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html>

## GitHub Actions

- Workflow syntax: <https://docs.github.com/en/actions/writing-workflows/workflow-syntax-for-github-actions>
- Reusing workflows: <https://docs.github.com/en/actions/sharing-automations/reusing-workflows>
- Security hardening: <https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions>


External literature only. These age on the field's clock, not the repo's.

## The consensus shape of a memory-debugging toolchain

The current consensus for memory-correctness testing of a C codebase is a
**layered pipeline**, because no single tool finds everything: static analysis
reasons about unexecuted paths but reports false positives; sanitizers and
Valgrind observe real executions with concrete stacks but only on paths actually
run; fuzzing generates the inputs that drive those paths. Leaks specifically need
both a detector and input that reaches the leaking path. The memory model in [05-debugging.md](05-debugging.md) is the c43-
specific reason this pipeline needs a fourth layer (application-level accounting
and a canary).

**Emerging - watch, not yet adopted here.** July-2026 research is pushing
LLM-assisted and metamorphic fuzz oracles (deriving oracles from code and
relations rather than crash-only signals) and fuzzing-based mutation testing to
score suite quality. Promising for the parser/decoder surface; not in our lanes.

Notes that are easy to lose:

- **`_FORTIFY_SOURCE` and the sanitizers do not mix** (OpenSSF, July 2026):
  FORTIFY's inline libc wrappers interfere with ASan/MSan interception and cause
  false or missed reports. Keep it for a *hardened* lane and drop it
  (`-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0`) in any `-Db_sanitize` build. Most
  distros default it on, so this must be active, not assumed. ASan, TSan and MSan
  are mutually exclusive with each other - one sanitizer per lane.
- `-ftrivial-auto-var-init=zero` (GCC 12 / Clang 8) deterministically zeroes
  automatic variables, neutralising a whole class of uninitialised-read bugs. It
  is in our warnings lane.
- MSan requires **every** linked dependency instrumented, including libc
  surrogates - which is why it is unbuildable here (GMP).
- TSan is irrelevant to a single-threaded simulator unless a threaded HAL
  appears.

## Reference list

Compiler hardening and warnings:

- OpenSSF Compiler Options Hardening Guide for C and C++ -
  https://github.com/ossf/wg-best-practices-os-developers/blob/main/docs/Compiler-Hardening-Guides/Compiler-Options-Hardening-Guide-for-C-and-C%2B%2B.md
- OpenSSF: FORTIFY vs sanitizer builds (same guide, "Sanitizers" section) -
  https://best.openssf.org/Compiler-Hardening-Guides/Compiler-Options-Hardening-Guide-for-C-and-C++.html

Sanitizers:

- AddressSanitizer - https://clang.llvm.org/docs/AddressSanitizer.html
- LeakSanitizer - https://clang.llvm.org/docs/LeakSanitizer.html
- UndefinedBehaviorSanitizer - https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
- MemorySanitizer - https://clang.llvm.org/docs/MemorySanitizer.html
- ThreadSanitizer - https://clang.llvm.org/docs/ThreadSanitizer.html
- SanitizerCoverage - https://clang.llvm.org/docs/SanitizerCoverage.html
- The Complete C/C++ Sanitizers Handbook -
  https://gist.github.com/MangaD/3b46e4c5ef4c63e44a21bed39ae64093

Leak detection:

- Valgrind Memcheck manual - https://valgrind.org/docs/manual/mc-manual.html

Fuzzing:

- libFuzzer - https://llvm.org/docs/LibFuzzer.html
- AFL++ - https://aflplus.plus/docs/fuzzing_in_depth/
- OSS-Fuzz - https://google.github.io/oss-fuzz/
- Trail of Bits Testing Handbook (fuzzing C/C++) -
  https://appsec.guide/docs/fuzzing/c-cpp/libfuzzer/
- A Comparative Study of Fuzzers and Static Analysis Tools (2025) -
  https://arxiv.org/pdf/2505.22052
- SoK: Prudent Evaluation Practices for Fuzzing -
  https://arxiv.org/pdf/2405.10220
- An Empirical Study of Fuzz Harness Degradation (2025) -
  https://arxiv.org/pdf/2505.06177
- Fuzzing-based Mutation Testing of C/C++ Software (2025/2026) -
  https://arxiv.org/pdf/2503.24100
- Metamorphic Fuzz Oracle Enhancement via LLMs (2026) -
  https://arxiv.org/pdf/2606.14164

Static analysis:

- clang-tidy - https://clang.llvm.org/extra/clang-tidy/
- Clang static analyzer / scan-build -
  https://clang.llvm.org/docs/analyzer/user-docs/CommandLineUsage.html
- cppcheck - https://cppcheck.sourceforge.io/

Build/coverage tooling:

- Meson built-in options (`b_sanitize`, `b_coverage`, `warning_level`,
  `werror`) - https://mesonbuild.com/Builtin-options.html
- Meson unit tests / `meson test` - https://mesonbuild.com/Unit-tests.html
- gcov - https://gcc.gnu.org/onlinedocs/gcc/Gcov.html
- llvm-cov - https://llvm.org/docs/CommandGuide/llvm-cov.html