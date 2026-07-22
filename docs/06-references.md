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
- `res/SCRIPTS/cli_automation_examples.txt` - the DSL's own reference, maintained by upstream: worked `--exec` examples for screenshots, stat graphs, programmed solve/draw, state save/load, the keyboard path and the power cycle. Read it before writing a script; it is the source for which names are scriptable and which need `press`. One caveat measured on Linux: it says `c47` chdirs to its own folder, but that chdir is `__APPLE__`-only (`c47-gtk.c:73`), so on Linux `c47` still needs the repo root as cwd
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


## External literature

These age on the field's clock, not the repo's.

### The consensus shape of a memory-debugging toolchain

The current consensus for memory-correctness testing of a C codebase is a
**layered pipeline**, because no single tool finds everything: static analysis
reasons about unexecuted paths but reports false positives; sanitizers and
Valgrind observe real executions with concrete stacks but only on paths actually
run; fuzzing generates the inputs that drive those paths. Leaks specifically need
both a detector and input that reaches the leaking path. The memory model in [04-debugging.md](04-debugging.md) is the c43-
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

### Recursion guards on an embedded C stack

C47 lets a program re-enter its own numeric engines (a solved program can
contain SOLVE; an integrand can contain INT), so unbounded recursion on the C
stack is a reachable user input, not a coding accident - and the DM42's stack
is a small fixed budget the tree does not even state (the STM32L476 linker
script sizes RAM, the DMCP OS supplies the stack). Upstream caps integrator
self-nesting with a depth counter (`MAX_INTEGRATOR_NESTING_DEPTH` in
`defines.h`, merged from !1598). The mature-interpreter consensus, for when
this class comes up again:

- **One budget per stack, not one per facility.** Lua bounds *all* nested C
  calls with a single `LUAI_MAXCCALLS` rather than a counter per entry point:
  the C stack is one resource, and per-engine counters compound in mixed
  nests (each engine can be at its own cap simultaneously).
- **Count-based guards are the portable floor; byte probes are the precise
  ceiling.** PostgreSQL's `check_stack_depth()` measures actual headroom
  against a recorded stack base (`max_stack_depth`, default 2 MB) - more
  accurate than frame counting, but it needs per-platform stack bounds, which
  DMCP does not expose. Newer Lua adds the same idea (`LUAI_MINCSTACK` free
  space) on top of the call counter.
- **Separate C-stack safety from language-level recursion accounting** -
  CPython's PEP 651 is the argument spelled out: the two limits protect
  different things and should not share one knob.
- **A depth cap is only half of the guard.** The abort must also unwind the
  interpreter's own state - in C47's case the subroutine return stack that
  each nested `execProgram` pushes - or the machine survives the abort with
  dangling state and fails later, far from the cause. Test the *state after*
  an abort, not just the absence of a crash.
- **The cap needs a stack-budget argument on the target**, not just on the
  simulator: a limit of N heavy frames is only known-safe once
  frames-times-size is measured against the device stack. The usage side is
  measurable without hardware - frame sizes read straight off the built ARM
  ELF with `objdump -d` (prologue `sub sp` plus the `stmdb sp!` callee
  saves), and a hijacked command returning the address of a local gives the
  live stack pointer on the device. The capacity side - what the DMCP OS
  grants - is stated in no public document, so it ends as a hardware
  measurement, not a datasheet lookup.

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

Embedded-world patterns for the high-level modules (the module-to-domain map is
[09-modules.md](09-modules.md); every link verified 2026-07-22):

- Cross-cutting embedded C discipline - the standards the field measures
  against:
  - BARR-C:2018, the Barr Group Embedded C Coding Standard (free PDF; the
    pragmatic bug-prevention standard, harmonised with MISRA) -
    https://barrgroup.com/sites/default/files/barr_c_coding_standard_2018.pdf
  - MISRA C - the safety-industry baseline - https://misra.org.uk/
  - Holzmann, "The Power of 10: Rules for Developing Safety-Critical Code"
    (NASA/JPL; rule 1 bans unbounded recursion - directly the solver-family
    nesting question) - https://spinroot.com/gerard/pdf/P10.pdf
  - SEI CERT C Coding Standard -
    https://wiki.sei.cmu.edu/confluence/display/c/SEI+CERT+C+Coding+Standard
- Language VMs on microcontroller budgets (the keystroke VM's peer group -
  how production interpreters live in tens of KiB of RAM):
  - MicroPython internals (compiler, qstr interning, the VM) -
    https://docs.micropython.org/en/latest/develop/index.html
  - MicroPython on constrained RAM (the budget playbook) -
    https://docs.micropython.org/en/latest/reference/constrained.html
  - eLua - full Lua on MCUs, the design tradeoffs -
    https://eluaproject.net/en_overview.html
  - mruby / mruby-c - Ruby VMs for sub-64 KiB targets - https://mruby.org/
- Input handling and file screening (the `.p47`/state screening pass, NIM,
  the decoder): LangSec - treat every input as a formal language and fully
  recognize before processing; the theory behind screen-then-load -
  https://www.cs.dartmouth.edu/~sergey/langsec/
- Event-driven state machines (keyboard shift planes, TAM, the modal
  editors): Samek, "Practical UML Statecharts in C/C++" and the QP framework
  - the embedded canon for hierarchical state machines -
  https://www.state-machine.com/psicc2
- Embedded GUI composition (screen compositor, softmenus, browsers): LVGL's
  draw pipeline - the reference open-source architecture for frame-buffer
  GUIs on MCUs (invalidation, task-based rendering) -
  https://docs.lvgl.io/master/main-modules/draw/draw_pipeline.html
- Key scanning and debouncing (the keyboard driver): Ganssle, "A Guide to
  Debouncing" - the standard reference, with measurements -
  http://www.ganssle.com/debouncing.htm
- Real-time memory allocation (the block pool and `freeList.c`'s peer
  group): TLSF - the constant-time, low-fragmentation allocator for RTOS use
  - http://www.gii.upv.es/tlsf/

Interpreters, virtual machines and embedded scripting (the language surfaces
mapped in [09-modules.md](09-modules.md)):

- Crafting Interpreters (Nystrom) - bytecode VMs, dispatch, Pratt expression
  parsing; the single best on-ramp - https://craftinginterpreters.com/
- Ertl: interpreter construction and dispatch techniques (threaded code vs
  switch) - https://www.complang.tuwien.ac.at/projects/interpreters.html
- Jim Tcl (the interpreter embedded in t47) - https://github.com/msteveb/jimtcl
- Ousterhout, "Scripting: Higher-Level Programming for the 21st Century" (the
  embedded-extension-language argument) -
  https://web.stanford.edu/~ouster/cgi-bin/papers/scripting.pdf

Calculator heritage (the behavioural spec of the keystroke language):

- Free42 (Thomas Okken) - an independent, actively maintained HP-42S
  reimplementation; the best cross-check for keystroke-language semantics -
  https://thomasokken.com/free42/
- The hpcalc.org literature archive (HP-41/42 owner's and programming
  manuals) - https://literature.hpcalc.org/
- HP Museum forum - where the DM42/WP43/C47 lineage is discussed by its
  authors - https://www.hpmuseum.org/forum/

Arithmetic engines:

- General Decimal Arithmetic (Cowlishaw) - the specification decNumber
  implements; authoritative for every rounding and special-value question -
  https://speleotrove.com/decimal/
- GMP manual - https://gmplib.org/manual/

Numerical algorithms (the solver family and the mathematics tree):

- Brent, "Algorithms for Minimization without Derivatives" (the root finder's
  method; free from the author) -
  https://maths-people.anu.edu.au/~brent/pub/pub011.html
- Mori, "Discovery of the double exponential transformation and its
  developments" (the integrator's tanh-sinh method, by its inventor) -
  https://www.kurims.kyoto-u.ac.jp/~prims/pdf/41-4/41-4-38.pdf
- NIST Digital Library of Mathematical Functions (special functions:
  Bessel, gamma, erf...) - https://dlmf.nist.gov/
- Golub and Van Loan, "Matrix Computations" (the linear-algebra canon; book,
  no canonical URL)

Recursion and stack safety (embedded interpreters):

- Lua `llimits.h` (`LUAI_MAXCCALLS`, the single C-call budget) -
  https://www.lua.org/source/5.4/llimits.h.html
- Lua C-stack overflow test suite (`cstack.lua`) -
  https://github.com/lua/lua/blob/master/testes/cstack.lua
- CPython PEP 651: Robust Stack Overflow Handling -
  https://peps.python.org/pep-0651/
- PostgreSQL `max_stack_depth` / `check_stack_depth()` -
  https://postgresqlco.nf/doc/en/param/max_stack_depth/
- SQLite run-time limits (expression depth, trigger recursion) -
  https://www.sqlite.org/limits.html

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