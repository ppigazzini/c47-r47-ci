# Debugging c43

Which detector can see which bug, how to run it, and the ways this project has
already fooled itself. If you read one page before chasing a bug in C47, read
this one.

The single most important idea here: **C47's memory model defeats the standard
tools.** The pool is one `malloc`, so an overrun inside it is invisible to ASan
and Valgrind, and a block never returned to the free list is invisible to LSan.
Reaching for ASan and concluding "clean" is the most common way to miss a real
bug in this codebase.

For how to drive the calculator and write tests, see
[03-testing.md](03-testing.md). For the lane scripts that run these detectors in
CI, see [05-ci.md](05-ci.md).


## 1. Why the standard tools are not enough

Verified in `../c43/src/c47/`:

- `ram` is a single `uint32_t *` (`c47.h:333`), `malloc`ed once in
  `config.c:1533`: `ram = (uint32_t *)malloc(TO_BYTES(RAM_SIZE_IN_BLOCKS));`
- The calculator sub-allocates from it via `allocC47Blocks` -> `freeListAlloc`
  (`memory.c:76`, `core/freeList.c`).
- GMP is separate: `allocGmp`/`reallocGmp`/`freeGmp` (`memory.c`) are installed
  with `mp_set_memory_functions` and use the plain libc heap, tracked in
  `gmpMemInBytes`.

Consequences, and they are the whole reason this page exists:

- **ASan, LSan and Valgrind see exactly one allocation** (plus GMP's). A pool
  leak returns no blocks and is invisible to them. A write past a pool block
  lands inside a valid libc buffer and is invisible to them.
- Therefore leaks need application-level accounting (Sections 4, 6) and
  intra-pool overruns need a canary (Section 5).
- Conversely, `--leakscan`/`--testmem` cannot see a libc-level error, and the
  canary cannot see a leak. **No single lane substitutes for another.**

## 2. The block, and the stride the canary must use

This is the single most important number on this page. From
`../c43/src/c47/defines.h:2208-2213`:

```c
#define BPB                 2 // 2^BPB = number of bytes per block
#define BYTES_PER_BLOCK     (1 << BPB)
#define TO_BLOCKS(n)        ((((uint32_t)n) + (BYTES_PER_BLOCK - 1)) >> BPB)
#define TO_BYTES(n)         (((uint32_t)n) << BPB)
#define C47_NULL            65535 // NULL pointer
```

- **A block is 4 bytes** - one `uint32_t` slot of `ram`. `TO_BLOCKS` rounds
  **up**; `TO_BYTES` is an exact shift.
- A C47 pointer is a **16-bit index into `ram`**; `C47_NULL = 65535 = 0xffff`
  is reserved, which is why RAM must stay below `2^16 - 1` blocks.
- `RAM_SIZE_IN_BLOCKS` (`defines.h:2048-2057`): simulator and testSuite
  (`!DMCP_BUILD`) get `RAM_SIZE_IN_BLOCKS_NEW_HW` = **65534 blocks = 262136
  bytes**. DM42 (DMCP, old HW) gets 16384 blocks = 65536 bytes. DMCP5 gets
  65534.
- Program memory grows **downward from the top of RAM**:
  `beginOfProgramMemory = (uint8_t *)(ram + (RAM_SIZE_IN_BLOCKS - 1));`

**The allocator stores no sizes.** Every wrapper takes `sizeInBlocks` and the
caller passes the original size back:

```c
void    *allocC47Blocks  (size_t sizeInBlocks);
void    *reallocC47Blocks(void *pcMemPtr, size_t oldSizeInBlocks, size_t newSizeInBlocks);
void     reduceC47Blocks (void *pcMemPtr, size_t oldSizeInBlocks, size_t newSizeInBlocks);
void     freeC47Blocks   (void *pcMemPtr, size_t sizeInBlocks);
```

This is the constraint the canary must respect: **all four wrappers must inflate
the size identically**, in blocks, or a free will mismatch its allocation.
Memory is not zeroed on allocation.

Accounting facts worth knowing before you measure anything:

- `getFreeRamMemory()` (`memory.c:6`) sums the free-list regions and **returns
  BYTES, not blocks**. It is fragmentation-immune as an absolute reading, but a
  delta between two readings is not a reliable pool-leak metric under alloc/free
  churn: free-list fragmentation over-reports. Trace orphaned blocks, or use
  `--testmem`, for a leak claim.
- `c47MemInBlocks` is pool occupancy; `gmpMemInBytes` is GMP's.
- `debugMemory()` prints both plus the free-region table. The testSuite prints
  it at exit and `processTests` returns
  `failedTests > 0 || gmpMemInBytes != 0` - **a GMP leak fails the run**.
- `isMemoryBlockAvailable()` peeks without consuming; `MAX_FREE_REGIONS` is 200
  on the sim, 50 on DMCP.

## 3. Detector-to-bug-class matrix

| Bug class | Detector that CAN see it | Detectors that are BLIND |
|---|---|---|
| libc heap overflow / UAF | ASan, Valgrind | pool lanes |
| Uninitialised read | Valgrind (MSan not built) | ASan |
| Undefined behaviour | UBSan | everything else |
| **Pool leak** (blocks never returned) | `--leakscan`, `--testmem`, `debugMemory` | ASan, LSan, Valgrind |
| **GMP leak** | `mpz_init`/`mpz_clear` `--wrap` count (Section 6); `gmpMemInBytes` **only on firmware GMP** | ASan (often), `gmpMemInBytes` on system libgmp |
| **Intra-pool OOB write** | **POOL_GUARD canary only** (Section 5) | ASan, Valgrind, leakscan, keyscan, testmem |
| Parser/decoder OOB | libFuzzer + ASan | corpus |
| Logic bug (wrong value) | corpus with value assertions | every sanitizer |
| Register/state collision | t47 sentinel battery ([03-testing.md](03-testing.md) Section 2) | every memory tool |

The last row matters more than it looks: two of the most recent real bugs (the
matrix editor clobbering I/J, and the STOVEL/RCLVEL off-by-one) are register
collisions. Both were initially suspected to be pool corruption and are not
memory bugs at all. Before reaching for a canary, ask whether the symptom is
corruption or a wrong contract.

---

## 4. Pool and GMP leak scanning

All three scanner modes come from **one** carried patch,
`scripts/test/tooling/leakscan.patch` (500 lines, touches only
`src/testSuite/testSuite.c`), off branch `test/ram-pool-leak-scanner`.

| Flag | Invocation | End sentinel |
|---|---|---|
| `--leakscan` | `testSuite --leakscan` | `LEAKSCAN done:` |
| `--keyscan` | `testSuite --keyscan` | `KEYSCAN done:` |
| `--testmem` | `testSuite --testmem <list>` | `TESTMEM done:` |

**All three exit non-zero by design.** Every lane asserts the end sentinel
instead of trusting the exit code - a truncated run would otherwise emit fewer
findings and pass the baseline diff as a false PASS.

### 4.1 `--leakscan` - the item sweep

Runs every item 1..2800 across the operand stack types in a **forked child** (so
a crash or hang is attributed and isolated), clears state with `fnClAll`, and
compares pool+GMP against baseline with the fixed 224-block `fnClAll` overhead
subtracted.

Operand types: real / string / long integer / complex, **plus** realMatrix (4),
complexMatrix (5), realVector (6), added later than the rest. Those three matter:
matrix functions bail on the data-type check before allocating, so with
scalar-only operands their alloc/free paths never run - which is exactly why the
gate missed a batch of upstream matrix leak fixes.

Two structural false positives, both baselined:

- **Persistent state is not a leak.** `fnEditLinearEquationMatrixA/B`
  (1202/1203) create `Mat_A`/`Mat_B`; `fnEqNew` (1465) creates an equation;
  `fnInDefault` (1889) refreshes display state. `fnClAll` does not delete named
  objects. `--leakscan` **cannot distinguish per-call leak from persistent
  state** - that is precisely why `--testmem` exists.
- **Most "crashers" are not user bugs.** The scanner calls handlers directly
  with `NOPARAM` from a clean state; in real use they are reached only through
  the keyboard/menu layer with proper context. A guard added without
  understanding the intended calling context can mask a real upstream contract.

### 4.2 `--keyscan` - the state-machine driver

Feeds realistic key sequences through the **real key path**:

```c
processKeyAction(item); if(!keyActionProcessed) runFunction(item);
```

**Both halves are load-bearing.** `processKeyAction` is what lets TAM consume
the *following* key; dispatch through `runFunction()` alone and TAM never does,
so `ui/tam.c` and the editors are never entered at all and STO/RCL sequences
crash. That single line is the only reason the interactive subsystems -
`differentiate.c`, `solve.c`, `tvm.c`, `ui/tam.c`, `ui/matrixEditor.c` - are
reachable from a headless driver; `run-coverage.sh` reports what they reach
today.

`executeFunction` is **not** the right entry: its state-machine block is gated
on `data[0] != 0`, a real key-label string, so it is skipped for the item-code
path.

Structural finding worth keeping in mind: real/complex arithmetic stores results
in the **fixed register area, not the pool**, so those paths cannot leak pool
blocks at all.

### 4.3 `--testmem` - per-test attribution

Runs the normal corpus, clears working state after each case, and reports any
case above a **running high-water mark**. The ratchet is not a detail: a naive
fixed baseline flagged 8848 cases; the high-water ratchet flags 24.

Confirm any finding by **running the offending test file twice - a real leak
doubles**; persistent state does not. (But see the doubling-test caveat in Section 12 - doubling is
necessary, not sufficient.)

The ratchet must ratchet **usage**, not the raw level. The original code did
`testMemPrevFree = freeNow` unconditionally, so a case that transiently *freed*
memory raised the bar and the next case looked like growth (`logxy` -1096 then
`toReal` +1096, net zero). The fix is to ratchet one way only:
`if(freeNow < testMemPrevFree)` / `if(gmpMemInBytes > testMemPrevGmp)`.

`--testmem` found six real matrix leaks. One deserves its method noted: the
`fnEvPFacts` leak was cracked by its **size fingerprint** - exactly 16 blocks per
matrix element (192 for 2x6, 224 for 2x7) = one full `real34` matrix copy,
independent of operand type, which fixed the search on "where is one matrix
copied and not freed". Another (`fnEigenvalues`) shows the cooperative input is
the red herring: the symmetric matrix leaks nothing; the flagged input is the
cyclic permutation with `FL_CPXRES` clear, expecting `EC=8`, whose error path
skips the free.

### 4.4 Running them

```bash
bash scripts/test/run-leakscan.sh
bash scripts/test/run-testmem.sh
UPDATE_BASELINE=1 bash scripts/test/run-leakscan.sh   # writes <baseline>.new; copy over MANUALLY
```

Both build with:

```
meson setup "$BUILD_DIR" --buildtype=custom \
    -DRASPBERRY="$raspberry" -DDECNUMBER_FASTMUL=true \
    -Dc_args="-Wno-deprecated-declarations"
```

## 5. The pool canary (POOL_GUARD) - the only detector for intra-pool OOB

**This technique is recorded nowhere else.** It is the only way to find writes
past a pool block, a class that ASan, Valgrind, leakscan, keyscan and testmem
are all structurally blind to (Section 1). It has found exactly two bugs, both
real, both invisible to every other lane.

### 5.1 The instrumentation

Instrument the `memory.c` wrappers under `#if defined(POOL_GUARD)`. Leave
`core/freeList.c` untouched - the guard belongs in the accounting layer.

- `allocC47Blocks(n)`: allocate `n + POOL_GUARD_BLOCKS`, fill the trailing guard
  with the canary.
- `freeC47Blocks` / `reallocC47Blocks` / `reduceC47Blocks`: **inflate the size
  identically** and verify the guard before releasing. Mandatory, not optional -
  the allocator stores no sizes (Section 2), so an un-inflated free mismatches
  its allocation and corrupts the free list.
- Verify at free time (attributes to the culprit via backtrace) **and** sweep
  every live region in a `checkPoolGuards()` at each test boundary, for blocks
  not freed soon.

### 5.2 The stride, and the canary that must not be constant

Two rules; the second one cost us a hidden bug:

1. **The guard is counted in BLOCKS of 4 bytes** (`BYTES_PER_BLOCK`, Section 2).
   `allocC47Blocks` takes blocks; `POOL_GUARD_BLOCKS` is a block count. Writing
   the guard means writing `POOL_GUARD_BLOCKS * 4` bytes at
   `(uint8_t *)p + TO_BYTES(n)`. Getting the unit wrong silently guards the
   wrong region and the sweep reads clean forever.

2. **Use a POSITION-DEPENDENT canary - each guard byte is a hash of its own
   address - never a constant byte.** A copy/shift overrun whose source is one
   past an adjacent buffer reads *that buffer's own guard*. With a constant
   canary it copies the canary into the target guard, the guard still matches,
   and the bug masks itself. This is exactly what hid the `insCol` overrun until
   the canary was made position-dependent.

### 5.3 The build and the sweep

```bash
cd ~/_git/c43
meson setup build.guard --buildtype=custom -DRASPBERRY=false -DDECNUMBER_FASTMUL=true \
  -Dc_args="-Wno-deprecated-declarations -DPOOL_GUARD -g -rdynamic"
ninja -C build.guard src/c47/vcs.h
ninja -C build.guard src/testSuite/testSuite
./build.guard/src/testSuite/testSuite src/testSuite/tests/testSuiteList.txt   # corpus
./build.guard/src/testSuite/testSuite --leakscan                              # item sweep
./build.guard/src/testSuite/testSuite --keyscan                               # subsystems
```

`-rdynamic` is what makes the free-time `backtrace()` attribution readable.

The item sweep **must** carry real/complex matrix operands (types 4/5) or matrix
overruns never trigger: scalar-only operands miss them, and `fnInsCol`/`fnInsRow`
are empty stubs anyway, so the sweep cannot reach the editor path at all.

### 5.4 The bug class it catches

POOL_GUARD is the only detector for the **intra-pool OOB write**: a store just
past a pool block, into an adjacent live block, that ASan and Valgrind cannot see
because it stays inside the one big `malloc`. Two patterns in
`mathematics/matrix.c` are the shape to watch, both **numerically silent** (the
result matrix looks correct, so no value assertion flags them) and reachable only
through specific ops:

- a matrix shift/insert loop bounded one column too long (`j < cols + 1` instead
  of `j < cols`), writing one element past the new matrix - the pattern in the
  `insColRealMatrix`/`insColComplexMatrix` family;
- a shared zero-init loop that runs across a large buffer and a smaller companion
  allocation (`previousDiagonal`, `size*2` reals versus the `size*size*2` bulk),
  overrunning the companion into the following block - the pattern in the
  eigenvalue path.

Both write only zeros or in-range values into a live block, so they corrupt only
in unlucky layouts - intermittent by nature, which is why this class survives
every other lane. The SIGSEGV item-sweep crashers are the known
headless-invocation crashers (Section 4.1), not this class.

## 6. GMP leak hunting - count `mpz_init`, do not trust `gmpMemInBytes`

**The most important false-negative on this page.**

A c43 host build links the **system libgmp**, whose `mpz_init` allocates
**lazily**. An initialised-but-never-assigned long integer holds no limbs, so
leaking it leaves `gmpMemInBytes` at **0**. A full BinetV3 sweep reported
`gmpMemInBytes == 0` and was wrongly written up as "not reproducible". The same
leak is 211552 bytes on the r47zen host build, which compiles the bundled
firmware GMP (`-DCALCMODEL=USER_R47`) and charges a limb on every `mpz_init`.

The technique that does not lie - **count the calls** via the linker:

```
-Wl,--wrap=__gmpz_init,--wrap=__gmpz_clear     (and the init variants in use)
```

```
before fix:  mpz_init = 2943, mpz_clear = 2840  -> 103 leaked long integers
after  fix:  mpz_init = 2840, mpz_clear = 2840  -> 0
```

Rule: **to hunt host-side long-integer leaks, count `mpz_init` vs `mpz_clear`,
or build against the firmware GMP. Do not trust `gmpMemInBytes` on system
libgmp.**

### 6.1 The double-init bug class

Systematic, and worth a dedicated grep on any new code: a caller does
`longIntegerInit(x)` then passes `x` to a converter that **also** initialises it,
orphaning the first allocation - one leak per call.

The re-initialising converters (all `registerValueConversions.c`):
`convertLongIntegerRegisterToLongInteger`,
`convertShortIntegerRegisterToLongInteger`, `convertReal34ToLongInteger`.
`convertRealToLongInteger` does **not** init (it uses the caller's).

To find them: grep callers of those three and flag any preceding
`longIntegerInit` on the same variable with no intervening free.

Known members: `getRegisterAsLongIntQuiet` (the BinetV3 trigger - CHS on a
long-integer loop counter, ~100 leaks per plot); `solver/isumprod.c`,
`solver/sumprod.c`, the `stringFuncs.c` x->alpha family, `printing/print.c`.
Fixes for these were developed on local branches that are not upstream and are
not reachable from a clone; treat the list as the map of the bug class, not as
a pointer to code. Checked clean: `prime.c`, `matrixEditor.c`,
`registerValueConversions.c:286`.

**Counter-example - do not "fix" this one.** `getRegisterAsLongIntQuiet`'s
*callers* own `val` and free it on error (e.g. `compare.c` frees `int1`/`int2`),
so adding a free inside would double-free.

### 6.2 The attribution trap

Upstream's own `items.c:620` diagnostic prints the **running total** after each
function. Reading it as a per-function attribution produced a completely wrong
audit scope (golden/power/root) when the real trigger was CHS. The first
non-zero total appears "after STO" and means nothing about where the leak is.
Instrument the specific call, or count inits.

## 7. Coverage

```bash
bash scripts/test/run-coverage.sh          # CI runs COVERAGE_MIN=45 SECTOR_GATE=1
```

Builds `-Db_coverage=true` with `-DKEYSCAN_COVERAGE_FLUSH`, stages
`testPgms.bin`, then runs **corpus + `--keyscan` + `--leakscan`** into the same
`.gcda`, and reports with `gcovr` filtered to `src/c47/`.

Three gotchas, all load-bearing:

- **`_exit()` in a fork child skips gcov's atexit handler.** The `--keyscan`
  children's coverage - exactly the subsystem code the driver exists to reach -
  was silently discarded. `KEYSCAN_COVERAGE_FLUSH` makes them call
  `__gcov_dump()` first. Applied to the **key-sequence children only**: the item
  sweep's thousands of forks would each rewrite the whole `.gcda` set.
- **gcov bug 68080** inflates loop counters in a few hot files and aborts gcovr.
  `--gcov-ignore-parse-errors suspicious_hits.warn_once_per_file` demotes it to
  a warning. Confirmed necessary on `charString.c`. Needs **gcovr >= 8**; apt
  ships 7, which is why CI installs it with `uv`.
- **Never rebuild the coverage build dir while a run is using it** - it corrupts
  the `.gcda` and reads new test files against the stale binary (false
  failures). To work on something else meanwhile, give the second run its own
  tree: `BUILD_DIR` and `HARNESS_WORK` are both overridable, and every lane wipes
  `$HARNESS_WORK/upstream` on entry, so two lanes sharing one `HARNESS_WORK`
  corrupt each other whatever the build dir says. The default here is
  `build.coverage` (`run-coverage.sh:32`).

### 7.1 The whitelist is the real coverage gate

`Func: fnX` is resolved by a linear search of `funcTestNoParam[]`
(`testSuite.c:4218`). Unregistered functions return "cannot find the function to
test". Whole **core** subsystems sit at 0% purely because their entry points are
unregistered, not because they are hard to test.

To find them: for each `src/c47/**/*.c`, list `^void fn...(uint16_t` entry
points; a module where 0 are registered but >=2 are declared is a target.
Registration rules, learned the hard way:

- names must be **<= 24 chars** (`funcTest_t.name[25]`);
- register only real `void fn(uint16_t)` entry points, **never internal
  helpers** - a 4-arg helper will segfault;
- header declaration names can differ from the `.c` definition; verify the decl
  or a clean grep still fails to compile;
- pass the function parameter with `FARG=` or `Func: name(n)`. A bare `Func:`
  line passes `NOPARAM` (9876), not the catalog value, so a newly registered
  function whose parameter selects behaviour is only half covered until the
  parameter is set - see [03-testing.md](03-testing.md) Section 1.


Two unlocks worth reusing:

- **curveFitting**: `fnCurveFitting` only *selects* models; the per-model math
  runs via `fnProcessLR` (resultType 1/2/4/7), which loops every bit of
  `lrSelection`. Register `fnProcessLR`, then `fnCurveFitting(511)` +
  `fnProcessLR(7)` hits all 9 model branches. 0 -> 72%.
- **serializers**: the test HAL `src/testSuite/hal/io.c` mapped only 4 of 15
  `ioFilePath_t` values; the rest returned FILE_ERROR so every save gave EC=55
  "cannot write file". Completing the switch unlocked the whole save/restore
  subsystem. Program serializers additionally need `-DPC_BUILD`.

### 7.2 Honest residuals

Documented **host ceilings**, not corpus gaps: `roundReal()` rounds via
`displayValueX`, the *rendered* display string - headless there is no renderer,
so `fnRound` on a real yields NaN. Same for `xfn.c` formatting. Every math
dispatch has `default:` bug-screen branches unreachable by valid dispatch.
Interactive editors need a key context.

The exit criterion is "every corpus-reachable math line covered, every residual
classified", **not** a flat percentage. Line coverage is not use-case coverage:
~2850 functions x operand shapes x mode families x stack contexts x path classes
is ~2.7M coarse cases - line coverage alone is not enough for a calculator.

Per-file lifts beat sector deltas when a big file was already partly covered:
`matrix.c` is 4157 lines = 21% of its sector and was already ~67%, so new cases
overlap. Clean wins are files genuinely cold: `iteration.c` 0->79,
`saveRestoreBackup.c` 0->80, `compare.c` 21->51.

## 8. Fuzzing

Three lanes, all libFuzzer + ASan + UBSan under clang:

```bash
FUZZ_TIME=120 bash scripts/test/run-fuzz.sh            # decodeOneStep
FUZZ_TIME=120 bash scripts/test/run-fuzz-equation.sh   # parseEquation
FUZZ_TIME=120 bash scripts/test/run-fuzz-restore.sh    # restoreCalc / backup.cfg
```

Common shape: `-Dfuzz_decode=true` (or `_equation` / `_restore`), gated off by
default so the gcc build is unaffected; `-fsanitize=fuzzer,address,undefined`
with `-fno-sanitize=alignment` (**the calculator packs program bytecode
unaligned by design**) and `-fsanitize-recover=undefined`.

Lessons that generalise:

- **The first bug dominates the input space.** The `getStringLabelOrVariableName`
  OOB blocked everything deeper; enlarging the harness buffer (so the trusted-
  length read stays in bounds) plus `-fork=1 -ignore_crashes=1` surfaced two
  more real bugs.
- **Seed from a structurally valid artifact.** `gen_backup.c` calls `saveCalc()`
  to make a ~1 MB valid seed, so mutations reach the field parsers instead of
  dying at the version/ramSize checks. Generated, never committed - it would
  drift with the format.
- **Turn LSan off where the harness churns persistent state**
  (`detect_leaks=0` in fuzz-restore); gate on memory errors instead.
- **Pick a non-evaluating parser mode**: `EQUATION_PARSER_MVAR` keeps the
  campaign on the tokeniser instead of recursing into the math engine.
- Harnesses need the GUI/screen globals (`screen`, `calcKeyboard`,
  `currentBezel`, `screenStride`, `screenData`, `screenChange`) to link.
- **The harness is code under test.** `fuzz_decode.c` built the step in a stack
  buffer but never set `beginOfProgramMemory`/`firstFreeProgramByte` to it, so
  bounded decoders were tested against an unrelated pool - false ASan crashes
  depending on stack-vs-pool address ordering.

The equation lane has a clean baseline (120 s = 4,937,252 execs, no finding).
The restore lane found a real one in ~1 s: a hexDump NULL-deref/overflow where
the byte count and the number of hex lines both come from the file on trust, so
**a corrupt `backup.cfg` crashes the calculator on boot**. Reproducer kept at
`scripts/test/tooling/fuzz-restore-repro/min-hexdump-oob.cfg`.

## 9. Valgrind

```bash
bash scripts/test/run-valgrind.sh          # VALGRIND_GATE defaults to 1 - gates by default
```

The **only** lane whose gate is on by default. Full corpus, no subset,
`--track-origins=yes`, `-g` build, suppressions in `tooling/valgrind.supp`
(suppress libraries, never c47 frames).

Three hard-won points:

- **memcheck prints basenames.** The original c47-site detector matched the
  literal string `src/c47/` against frames that read `matrixEditor.c:984`, so it
  matched nothing: `valgrind-found.txt` was always empty and the gate was
  **inert**, detecting zero of the six real findings. The matcher is now driven
  by `find "$UPSTREAM_DIR/src/c47" -printf '%f'`. Attribute access errors to the
  **innermost** frame and leaks to the **first c47 frame** in the allocation
  stack. `--error-exitcode=0` is kept deliberately: valgrind's own exit would
  trip on third-party noise, so the scoped baseline diff is the gate.
- **Do not subset the corpus for memcheck.** Runtime is not spread across it but
  concentrated in a few iterative solver/integration tests (tvm, solve,
  integrate, sumprod, iteration, curveFitting). A random subset that happens to
  exclude those runs fast but gives no signal: it skips the most
  allocation-heavy tests, which are the ones most worth leak-checking. Full
  corpus with `timeout-minutes: 350`.
- **Regenerate the baseline ON THE RUNNER.** The uninitialised-read line set is
  toolchain-dependent; CI's valgrind flags more sites in `real34ToDisplayString2`
  than a typical local install. A locally-regenerated baseline is missing
  runner-only sites and the gate fails.

Current baseline: 8 entries, all uninitialised-value reads plus one
`possibly lost @ config.c:1713`; definitely/indirectly lost stay **zero**,
because c47 is malloc-clean (it sub-allocates from its own pool). Any new c47
site is a real finding. The baseline is **line-number keyed** against a moving
upstream - a legitimate upstream edit that shifts lines fails the gate until
refreshed. That is the intended cost of a strong regression gate.

## 10. Static analysis and warnings

```bash
bash scripts/test/run-staticanalysis.sh    # cppcheck, ANALYSIS_GATE=0
bash scripts/test/run-warnings.sh          # OpenSSF set, WARN_GATE=0
```

**A static-analysis baseline is a TRACKED list, not a cleared one.** Re-reading
entries triaged "benign" is where the real bugs hide - a comparison operator
misplaced inside `abs()` so the distance collapses to a boolean, or a
first-sample seed made dead by a misordered `count == 0` guard nested inside
`count > 0`. Neither shows up as a warning once triaged, so the re-read is the
only thing that catches them.

cppcheck's known blind spot: it **does not track init-via-output-parameter
across functions**, which is the entire source of the GMP `uninitvar` false
positives. Line-scoped suppressions **drift** with upstream - a documented
fragility.

The warnings lane uses the OpenSSF hardening set including
`-ftrivial-auto-var-init=zero`; `-Wconversion`/`-Wsign-conversion` are
deliberately omitted as baseline noise. It has found **zero bugs** to date
(shadow / cast-qual / format-nonliteral only) - it is a regression fence, not a
hunting ground.

## 11. Sanitizer policy

`UBSAN_OPTIONS=halt_on_error=0` (report mode), `ASAN_OPTIONS=halt_on_error=1`
(hard gate). The reason is specific: with UBSan halting, the **first
upstream-owned UB aborts the run before the leak workload runs**, defeating the
lane. The core is upstream-owned, so ASan stays the gate. A per-finding UBSan
suppression list is not the answer either: upstream moves across hundreds of
commits, so the list would be perpetually stale and would still abort on the
next new UB.

`-fno-sanitize=alignment` is mandatory - c47 has pervasive intentional
misaligned access by design (the `manage.c` `programList_t` pattern). **A finding
reproduced identically on GCC and Clang is c43-owned**, not a compiler artifact.

Known third-party noise, excluded and not filed: `dep/decNumberICU/decNumber.c`
signed-left-shift UB (`:5541`, `:2261`), `decBasic.c:1194`, the decQuad FMA
uninitialised remainder read, `factorial.c:41` float-cast-overflow. The
build.asan meson `test` wrapper forces `halt_on_error=1` and aborts on the
decNumber shift - run the testSuite binary directly with
`UBSAN_OPTIONS=halt_on_error=0` for the real tally, and set
`LD_LIBRARY_PATH=$HOME/.local/lib` for xlsxio.

GTK leak attribution: a finding is a c43 bug only if the **direct allocating
frame** is in `src/c47*`/`src/t47`, or c43 drops a documented **transfer-full**
pointer. `moveLabels` topped 49 leak blocks that were all fontconfig cache
reached through a non-owning call - not a bug. The real one:
`gtk_widget_get_tooltip_text()` is transfer-full and must be freed (148
records); the adjacent `gtk_button_get_label`/`gtk_label_get_text` are
transfer-none and **freeing them would be a use-after-free**.

MSan is deliberately **not built**: it needs an instrumented libc *and GMP*, and
GMP is not available instrumented. The consequence is honest and recorded -
uninitialised reads have no dedicated detector; Valgrind is the fallback.

---

## 12. False-pass hazards - the catalogue

Every one of these has silently passed a broken thing at least once.

1. **A scan mode's exit code is meaningless** - all three exit non-zero by
   design. Assert the `LEAKSCAN done` / `KEYSCAN done` / `TESTMEM done`
   sentinel, or a truncated run passes the baseline diff.
2. **An orphaned `*_cov.txt` never runs.** A corpus file created and registered
   in `funcTestNoParam[]` but **not added to `testSuiteList.txt`** silently never
   executes; the suite stays all-green and the commit falsely claims coverage.
   Real case: `statsx_cov.txt` shipped un-listed, caught in adversarial review,
   not by the passing suite. After adding corpus files, diff the created set
   against the list and **confirm the per-case pass count rises** by the number
   of new `Out:` lines. Sigma-accumulating files must lead and trail with
   `fnClSigma` so they neither inherit nor leak sigma state.
3. **A stale bitmap fakes a graph pass.** `covHashBmp()` SHA-256s
   `c47plotTest<N>.bmp` **read from disk**, and `covBmpName()` only *names* the
   target - nothing unlinks it. If the graph program errors before `SNAP`, the
   hash test passes against the **leftover bitmap from an earlier passing run**.
   Verified A/B on the same unfixed binary: clean dir -> 2 failures; bitmaps left
   over -> **1** failure. This is why the failure count is not stable across
   runs. **`rm -f c47plotTest*.bmp` before bisecting graphs_cov.**
4. **`dirname(listPath)` decides where the corpus is found.** Writing a list to
   `$LOG_DIR` made testSuite find no test files, exit in ~1s with
   `0 errors from 0 contexts`, and run **nothing**. Write generated lists beside
   the corpus.
5. **`grep` with no match under `set -Eeuo pipefail` aborts the lane.** A
   comments-only baseline made the diff step exit 1. Wrap: `{ grep ... || true; }`.
6. **A stale build is not evidence** (Section 7 method discipline in [03-testing.md](03-testing.md)).
7. **Stale `src/generated/` shadows the build dir.** `src/c47/meson.build` sets
   `c47_inc = include_directories('.', '../generated')`, so the gitignored,
   hand-populated `src/generated/*` is on the include path and **shadows** the
   freshly regenerated build-dir headers. Those files are populated by the
   Makefile's `install -C` step, **not by ninja**, so building a single target
   leaves them stale - producing errors like `const39_fpfToMph undeclared` even
   though the build dir is correct. Mirror the install step after any upstream
   constant/catalog change. `src/generated/constantsVerification.txt` is tracked
   and regenerated - `git checkout --` it before any history rewrite.
8. **`ninja -C $BUILD_DIR src/c47/vcs.h` first, always.** Meson does not wire the
   generated `vcs.h` as a dependency of every source, so a fresh parallel
   testSuite-only build races.
9. **Run the testSuite from a scratch CWD** - it writes `REGS.TSV`, `.bmp`,
   `backup.cfg`, `c47.sav` into the current directory - **but stage
   `testPgms.bin`** ([03-testing.md](03-testing.md) Section 5) or you manufacture six false failures and a
   dead-looking program engine.
10. **Test order leaks state** ([03-testing.md](03-testing.md) rule 6.6).
11. **`fnRefreshState` is a no-op** (`{ doRefreshSoftMenu = true; }`). Two
    separate investigations attributed a leak to it. Instrument the actual call
    before believing an attribution.
12. **The doubling test is necessary but not sufficient.** `toReal +1096`
    doubled on every pass and looked exactly like a real context-dependent leak.
    The +1096 was allocated **inside the tooling's own
    `testMemClearWorkingState()`** - its `clearRegister` loop writes canonical
    real34-zero into ~136 registers x ~8 blocks = 1088. A per-case reset that
    itself allocates reproduces on every pass.
13. **A leak report shows the allocation site, not the overwrite site.** ASan
    blamed `_dynmenuConstructUser`; the buffer was allocated correctly. Two
    obvious fixes were tested and disproven (free-before-malloc gave 18
    double-frees; freeing at teardown leaves the leak if the block is already
    orphaned). A **gdb hardware watchpoint** on
    `dynamicSoftmenu[0].menuContent` finds a culprit that no source grep can -
    a field nulled without freeing writes nothing textually greppable. (In
    `runPgm`, `testSuite.c:709`, the buffer is freed before the pointer is
    dropped.)
14. **GTK transfer-full vs transfer-none** (Section 11).
15. **A gate can be inert for its whole life** - the valgrind basename bug
    (Section 9). Prove it fires ([03-testing.md](03-testing.md) rule 7.7).
16. **A "clean" sentinel result may mean the fix is applied**, not that the bug
    is absent. Check the branch ([03-testing.md](03-testing.md) Section 2.1).
17. **A convenient sentinel hides the interesting failures.** I=7 J=9 round-trips
    through the `int16_t` matrix-index backup unharmed, so it reports the
    off-by-one and nothing else; the same path silently flattens I=0.35 to -1,
    I=99999 to -31074 and a complex to a long integer ([03-testing.md](03-testing.md) Section 2.1). Pick sentinel values
    that exercise the width, the fraction and the type, not just the arithmetic.
18. **`git stash` does not revert a commit.** Stashing to "get back to master"
    leaves a committed fix in the tree, and the A/B then compares the branch with
    itself and agrees. Check out the ref, force a rebuild (Section 7 method discipline in [03-testing.md](03-testing.md)), and print the
    resolved HEAD in the same command that prints the reading (16, 6).

## 13. Current gaps

Re-verify this table against `scripts/test/` before quoting it: it names lanes
and their limits, and those move with the tree.

| Technique | Status here | Gap |
|---|---|---|
| Warnings/hardening | `run-warnings.sh`, 294 baselined | report-only; no `-Werror` lane |
| ASan + LSan | analysis lanes, hard gate | malloc-only; blind to the pool |
| UBSan | analysis lanes, report mode | not in upstream CI |
| **MSan** | **none** | uninitialised reads have no dedicated detector (needs instrumented GMP) |
| Valgrind | `run-valgrind.sh`, gates by default, curated `.supp` | line-keyed baseline drifts with upstream |
| Pool/GMP leak audit | `--leakscan`/`--keyscan`/`--testmem`, both hard gates | - |
| **Intra-pool OOB** | **POOL_GUARD, manual only** | **not wired into any lane (Section 14)** |
| Fuzzing | 3 lanes (decode/equation/restore) | report-only; OSS-Fuzz never onboarded; state-import + NIM unfuzzed |
| Static analysis | cppcheck lane, 22 baselined | **no clang-tidy** (needs an upstream `.clang-tidy`), **no scan-build**, **no `-fanalyzer`** |
| Coverage | `run-coverage.sh`, gates 45% + 5 sector floors | solver/graph 26% is a real functional gap; ui/input/dmcp are host ceilings |
| Differential numeric | `numeric-vectors.py`, 135 cases | single-argument only; no pow/atan2/logxy, no complex domain, no signed-zero/inf/NaN; no CI regeneration check |
| Unit isolation | fork-per-item in the scans | the corpus itself is one monolithic binary |

## 14. Open

- **Unbounded integrator recursion** (`keyscan CRASH seq=integrate_pgm_x20`).
  The keyscan driver's 20x replay folds the integrate keys into the stored
  program, so the integrand integrates itself (`_integratorIteration` ->
  `execProgram` -> `_executeOp` op=1690 -> `fnIntegrateYX` -> ...). There is no
  depth guard across `integrate`/`execProgram`. A guard must not regress
  legitimately deep recursion, so it needs its own analysis; until then the
  baseline entry carries the crash.
- **POOL_GUARD is not wired into any lane** - a manual sweep only (Section 15,
  Risks).
- **`covBmpName()` should unlink its target bitmap** so a skipped SNAP fails
  loudly instead of hashing history (the stale-bitmap hazard in Section 12). Proposed, not implemented.
- **Fuzz harness M3**: extend to `scanLabelsAndPrograms` + label-exec/menu paths
  so the copy-paste findings regress automatically. The harness lives here, not
  in c43.
- **MSan** remains unbuilt (needs instrumented GMP).
- **Differential vectors**: two-argument functions, complex domain, special
  values; plus a CI reproducibility check (needs mpmath on the runner).
- The `res/PROGRAMS` workload harness pins an `expected_display_hash`; **a
  deterministic image hash cannot distinguish an intended render change from a
  rendering regression.** Re-pinning is a maintenance point, not a formality.

## 15. Risks

- Section 5 (POOL_GUARD) is not wired into CI. It is a manual sweep and the two
  bugs it found were both intermittent by nature. If the class recurs, nothing
  catches it automatically.
- The valgrind baseline is line-number keyed against a moving upstream
  (Section 9).
- `coverage-floors.txt` has no `UPDATE_BASELINE` path - the only baseline edited
  by hand. Lowering a floor is an explicit, documented acceptance of a
  regression.
- The carried `leakscan.patch` drifts if upstream changes `testSuite.c`; the lane
  fails loudly and the patch must be regenerated from a rebased
  `test/ram-pool-leak-scanner`.
- This file is gitignored and has no history. Back it up before rewriting.

---