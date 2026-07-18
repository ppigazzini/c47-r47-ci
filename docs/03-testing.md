# Testing c43

How to drive the calculator and how to write a test that actually tests. The
detectors - leak scanning, the pool canary, fuzzing, Valgrind - and the
false-pass catalogue are in [04-debugging.md](04-debugging.md). The lane scripts
that run all of this in CI are in [05-ci.md](05-ci.md).

## The one-line version

```bash
make test     # builds the testPgms fixture, then runs the corpus
```

**It passes clean**, so a failure is a regression, not a baseline to compare
against. The target depends on `testPgms` and generates the fixture first;
run the binary without it and the corpus reports failures that are fixture
artifacts, not defects (Section 6). Read the summary the run prints rather
than a count written down here - it moves with upstream.

## The three ways to drive it

| driver | what it is | use it when |
|---|---|---|
| `testSuite` | the corpus runner: reads `.txt` files, calls functions directly | asserting a computed value |
| `t47` | the simulator plus a Jim/Tcl DSL, forced headless | you need state set up, a program run, or a register read |
| `c47` under `xvfb-run` | the same binary with its GTK front end, so real key presses work | the path is only reachable through the keyboard or a menu |

The corpus never touches the keyboard, the menus, or the screen. Anything
reached only through those is verified by human inspection unless you drive the
GTK binary yourself.


Four drivers, ascending in realism and descending in convenience. Pick the least
realistic one that can reach the bug.

## 1. Headless testSuite (the corpus)

```bash
cd ~/_git/c43
meson setup build.sim --buildtype=custom -DRASPBERRY=`tools/onARaspberry` -DDECNUMBER_FASTMUL=true
ninja -C build.sim src/c47/vcs.h                       # ALWAYS first (04-debugging Section 12)
ninja -C build.sim src/testSuite/testSuite
./build.sim/src/testSuite/testSuite src/testSuite/tests/testSuiteList.txt
```

Corpus size as of upstream `master` on 2026-07-18: **324 test files in
`src/testSuite/tests/`, 319 listed** in `testSuiteList.txt`. (Both numbers move;
re-count rather than quoting this line.)

A file that is not listed in `testSuiteList.txt` never runs, and the suite stays
green while reporting the same pass count - add a corpus file and confirm the
count rises, or the file is decoration. `conversions.txt` and `conversionsSI.txt`
are **regenerated on every build** (`src/generateTests/meson.build`), so a
hand-written case placed there is destroyed; hand-written conversion cases belong
beside `tempConv.txt`.

- The corpus grammar is documented in the header comment of
  `src/testSuite/tests/testSuiteList.txt` - **that comment is the authority**,
  not this page. Directives: `Func:`, `Item:`, `In:`, `Out:`, `Desc:`,
  `Desc_prefix:`, `Desc_suffix:`, `Timer:`. Register types
  `LonI Stri ShoI Real Cmpx Time Date ReMa CxMa`. `FARG=n` is the `uint16_t`
  passed to the function. `PGM="Name"` selects a global label for
  `Func: fnExecute`. Matrices are `"M2,2[1,2,3,4]"`; `any` / `?` skip an element.
- `Func:` resolves against the `funcTestNoParam[]` whitelist
  (`testSuite.c:75-638`), **not** the item catalog - see the coverage section of [04-debugging.md](04-debugging.md).
- `Item:` (`testSuite.c:4311`) drives the **real dispatch chain**
  (`reallyRunFunction`), unlike `Func:` which calls the handler directly. It
  accepts an `ITM_` name resolved by parsing `src/c47/items.h` at runtime, so it
  cannot go stale. Prefer `Item:` when the undo/stack-lift wrapper is part of
  what you are testing.
- **`Item:` passes the catalog's own parameter; `Func:` does not.** The two arms
  at `testSuite.c:4174` and `:4180` are `funcToTest(functionParameter)` against
  `reallyRunFunction(functionIndex, indexOfItems[functionIndex].param)`. A bare
  `Func:` line leaves `functionParameter` at **`NOPARAM` (9876, `items.h:2992`)**,
  which is not a value any catalog item passes. Where the parameter selects
  behaviour, that reaches only the branch 9876 happens to fall into, and where it
  is read as data the function is handed 9876 as the datum. Set it explicitly
  with `In: FARG=n` (`testSuite.c:1941`) or `Func: name(n)`
  (`testSuite.c:4214`) - both write the same variable - or use `Item:` and get
  the catalog value for free.
- **A value is compared to 30 significant digits, not 34.** A mismatch is
  reported only when `correctSignificantDigits < 30` (`testSuite.c:2775,2781`),
  so the last four digits of a 34-digit expectation are documentation, not
  assertion: a result wrong only in those digits passes. Pin a result that
  matters on its exponent or on an error code.
- **An `In:` line sets only what it names.** A setting it omits keeps the value
  the previous case left, and the per-file preamble is applied once at the top
  rather than before every case - so one case setting `SS=8` silently moves every
  later case in the file to eight levels. Settings also persist **across** files,
  in list order: `matrixIndex`, the stack size, `denMax` and the angular mode all
  survive into the next file. Name every setting a case depends on, and leave a
  changed setting as you found it.
- **A `*Cov` driver hides a function from name-based coverage counting.** 25
  entries in `funcTestNoParam[]` are `fn...Cov` wrappers that set up context and
  then call the real function - `covEff` stores the TVM variables and calls
  `fnEff`, for instance. The wrapped function carries no `Func:` line of its own,
  so counting coverage by name reports it as untested when it is not.
- `abortTest()` counts a failure and continues (its `exit(-1)` is commented
  out), so one bad case never stops the run. This makes the corpus a good
  carrier for assertion-style tests.
- The test HAL `src/testSuite/hal/io.c` maps every writable path to a
  **Test-suffixed** name (`backupTest.cfg`, `c47Test.sav`, `c47programTest.bin`,
  `c47stateTest.bin`, `c47regdumpTest.txt`). See rule 6.9 below.

## 2. t47 - the headless scripted simulator (the workhorse)

`t47` is **not a separate program**: it is a copy of the `c47` or `r47` GTK
binary built into `build.sim.t47` with `-DT47`, which only silences debug output
(`defines.h:419-458`). Headless is selected by **the binary's basename**
(`c47-gtk.c:371-380`), so `./c47 --headless ...` is identical to `./t47 ...`.

```bash
cd ~/_git/c43
make simc47 t47          # EXACTLY this. A bare `make t47` builds the R47-based t47.
./t47 --reset --exec 'nim 2; nim 3; xeq +; puts "X=[reg X]"'      # -> X=5
```

Jim Tcl is linked into `c47` and `r47` too, so the DSL is always available.
`initDSL` registers, in order: all standard Jim Tcl (`puts`, `set`, `expr`,
`proc`, `for`, `exec`, `string`, ...); then every catalog function as a
lowercased command (999 of 1042 on the current build); then the DSL commands
**last, so they override same-named catalog functions**.

| Command | Signature | Notes |
|---|---|---|
| `item` | `item <number> [arg] [#comment]` | By item code, bypasses name lookup. `1..LAST_ITEM-1`. |
| `catfn` | `catfn <name> [arg]` | By name. Needed for names that are not legal Tcl identifiers: `catfn STO+ 00`. |
| `xeq` | `xeq <label> [arg]` | Runs a global label; falls back to a catalog function if no label matches. Sets `dynamicMenuItem = -1` first. |
| `nim` | `nim <string>` | Types a number key-by-key then `closeNim()`. First `nim` -> Y, second -> X. `-` is deferred and emitted as CHS (RPN semantics). |
| `reg` | `reg <name>` / `reg <name> <value>` | Read/write a register. **Returns a Jim value - wrap in `puts`.** Matrices return `<unsupported>`. |
| `var` | `var <name>` / `var <name> <value>` | Same, but **creates** the named variable. |
| `flag` | `flag <name>` / `flag <name> <0\|1>` | `flag SPCRES 1`. |
| `readp` | `readp <file>` | Load a `.p47` (Section 4). |
| `xportp` | `xportp <label> <file>` | Export a program. |
| `loadst` / `savest` | `[<file>]` | State `.s47`. |
| `impreg` / `expreg` | `expreg <reg> [<file>]` | Registers `.d47`. |
| `snap` | `snap [<base>]` | Writes `<base>.bmp` + `<base>.REGS.TSV`. |
| `menu`, `asn`, `tsvfn` | see `src/t47/dsl.c` | Menu / key assignment / TSV log. |
| `press` | **GTK-only, NOT registered headless** | Section 3. |

Value literals (`src/t47/value.c`): real `2.5`; complex `"3 + ix4"`; short
integer `"FF#16"` (base 2..16); long integer `"12345678901234567890"`; date
`"2024-06-21"`; time `"18:30:45"`; otherwise a string. Register args accept
`0..99`, a letter from `"XYZTABCDLIJKMNPQRSEFGHOUVW"`, or a named variable.
`.NN` local registers and `->` indirection are **rejected in scripts**.

Flags that matter:

- `--reset` - `fnReset(CONFIRMED)` instead of `restoreCalc()`; prints
  `Factory reset: backup.cfg not loaded`. **Use it for every reproducible run.**
- Scripted runs never write the config back (`gtkGui.c:100-110` guards
  `saveCalc()` on `!scriptingActive`), so a script cannot corrupt your state.
- `--snapskiprefresh` - `fnSNAP` skips `refreshScreen(80)`, preserving drawn
  PIXEL/POINT/plot pixels.
- `--script <file>` (`-` = stdin), `--dslcommands` (dumps the ops table and
  exits), `--testPgms`, `--writeexportall`.
- **main() returns the Jim return code**, so `./t47 --exec '...'` exits non-zero
  on a script error - usable directly in a shell gate.

### 2.1 The sentinel battery

Plant a sentinel, run the operation, read the sentinel back. The cheapest
bug-finding tool on this page; needs no instrumented build.

```bash
# I=7, J=9, build a 2x2 matrix (1536 = M.NEW), open the editor (1529 = M.EDIT)
./t47 --reset --exec 'nim 7; item 44 I; nim 9; item 44 J; \
                      nim 2; nim 2; item 1536; item 1529; \
                      puts "I=[reg I] J=[reg J]"'
```

`item 44 I` is STO I. This prints **`I=7 J=9`**: the matrix editor keeps its
cursor in a shadow pair (`shadowI`/`shadowJ` in `ui/matrixEditor.c`, routed by
`ijIsShadowed()`), so it does not touch the user's I/J, and the vector functions
(STOVEL/RCLVEL/STOVEC/RCLVEC) bracket their index access the same way. INDEX
writes I/J by purpose; nothing else should. A register that **drifts** here is a
scratch value escaping into user space - the exact failure the battery exists to
catch.

**Check which branch is built before reading any result** - a "clean" result may
mean a fix is applied, not that a regression is absent.

Why this class matters: SPIRALk reads I as scaling factor and J as growth rate
with **0 as the "use default" sentinel**, so a stray scratch write of 0 or 1
into I/J silently changes radius = I*e^(J*angle) - a wrong graph with no error,
no crash, and nothing for a value assertion to flag. Register collisions read
like data corruption but are not; before reaching for a memory tool, ask whether
a scratch value escaped.

**Choose the sentinel adversarially.** An integer like 7 round-trips cleanly
through code that silently corrupts fractions, wide values and non-real types -
a lossy `int16_t` save/restore, a type coercion. Probe `0.35`, `99999` and a
complex `3+ix4`, not just `7` and `9`: `0.35` returning `-1`, or `3+ix4`
returning a long integer, exposes a truncating round-trip that integer sentinels
sail straight through.

Two register writes the battery flags are **by design - do not fix them**:
FACTORS (1477) rolls G<-H<-K deliberately (it stores the last three factors in
G, H, K), and monadic XFN zeroes T/A/B because XFN owns six registers as two
triples. Safe spare registers for user-program parameters are **E, F, O, U, V,
W** only.

## 3. GTK simulator under xvfb (when only a real key press will do)

Needed when the path is reachable only through the keyboard/menu layer: the
matrix editor (MIM), program editor (PEM), equation editor (EIM), TAM parameter
entry.

```bash
cd ~/_git/c43            # MUST run from the repo root: res/ CSS is cwd-relative
xvfb-run -a ./c47 --reset --exec 'press 1; press ENTER; puts "X=[reg X]"'
```

`c47` and `t47` are **the same binary**, byte for byte (`md5sum c47 t47`
matches): `main` reads `argv[0]` and `t47` forces headless, which is why `press`
is absent there and present here. Build both with `make simc47 t47` **exactly** -
a bare `make t47` builds the R47-based t47 instead.

**Only `press` reaches the keyboard and menu decode.** `item` and `xeq` call the
function directly, so anything behind TAM parameter entry or a softmenu is
unreachable without it - a name taking a TAM argument (`M.EDITN`) is not
scriptable at all. Driving the matrix editor to cell 2;2, which `snap` then
shows as `2;2=`:

```bash
xvfb-run -a ./c47 --reset --exec 'nim 3; nim 3; item 1526 00; item 51 00; item 1529; press F6; press @f; press F6; snap'
```

`1526` is M.DIM, `51` RCL, `1529` M.EDIT; in M_EDIT `F5`/`F6` are left/right and
the f-shifted pair is up/down. M.EDIT indexes X, so a later `nim` pushes the
matrix out of X - index a numbered register instead when the test needs the
stack, and note a program stops at M.EDIT.

- `gtk_init` runs unconditionally (`c47-gtk.c:428`), so a DISPLAY or `xvfb-run`
  is required **even headless**.
- The repo root is mandatory for the GUI: `prepareCssData()` (`gtkGui.c:1974`)
  does `fopen(CSSFILE, "rb")` on `res/c47_pre.css` and calls `exit(1)` on
  failure. `res/testPgms/testPgms.bin`, `backup.cfg`, `PROGRAMS/`, `STATE/`,
  `DATA/` are cwd-relative too. **On macOS only**, `main` chdirs to the
  binary's own directory first (`c47-gtk.c:73`, `#if defined(__APPLE__)`, and it
  skips the chdir when `argv[0]` is `t47`), so a Mac tolerates any cwd and Linux
  does not. Upstream's own DSL notes describe the chdir without that condition;
  on Linux, `c47` from a foreign cwd dies with
  `error opening file res/c47_pre.css!`.
- **`press` takes ONE key per call** (`press 1; press ENTER`), or a Tcl list.
  Not registered headless because `scriptInjectGtkKey` needs a realized window.
- Tokens: `F1`..`F6` (softkeys); `@f` / `@g` (shift toggles); `@k NN`; a single
  ASCII char; `ENTER`; `R/S`. Case-insensitive for `ENTER` and `R/S`. **`Return`
  is not a token** - the name is only the GDK keyval `ENTER` injects, and
  `press Return` is rejected.
- **`@k NN` is the 0-based index into `kbd_std_C47[37]`** (`assign.c:8`), NOT the
  printed keyID: `@k 00`=SUM+(21), `@k 05`=XEQ(26), `@k 06`=STO(31),
  `@k 07`=RCL(32), `@k 12`=ENTER(41), `@k 14`=CHS(43), `@k 16`=BACKSPACE(45),
  `@k 27`=fg(71), `@k 32`=EXIT1(81), `@k 35`=R/S(84), `@k 36`=ADD(85).

## 4. Programs and `.p47`

`.p47` is **plain ASCII**, one decimal byte value per line after a six-line
header (`saveRestorePrograms.c:12-29`):

```
PROGRAM_FILE_FORMAT
0                          <- BACKUP_FORMAT
C47_program_file_version
1                          <- PROGRAM_VERSION
PROGRAM
132                        <- size in bytes
1                          <- first program byte
...
255
255                        <- .END. if last program in memory
```

`WP43_program_file_version` is also accepted (with an "experimental" warning).
Extensions (`src/c47/hal/io.h`): `.p47` programs, `.s47` state, `.d47` data,
`.rtf`/`.txt` human-readable exports.

```bash
./t47 --reset --exec 'readp res/PROGRAMS/SPIRALk.p47; xeq SPIRALk; puts "X=[reg X]"'
./t47 --reset --exec 'readp ./docs/appnotes/sources/AN0022b_programs/func.p47; xeq PLTROOT'
```

`readp` -> `setReadpFilenameOverride` (`dsl.c:77`) mirrors the UI resolution:
use the path as-is if it exists; else if it has no `/`, try `PROGRAMS/<name>`;
else let `fnLoadProgram` report the failure. The plumbing is
`_ioFileNameOverride`, which the GTK HAL **consumes once and clears**
(`src/c47-gtk/hal/io.c:89`). That is how `readp`, `xportp`, `loadst`, `savest`,
`impreg`, `expreg` and `snap` bypass the GTK file chooser.

`fnLoadProgram` is item **1567** (READP); `fnSaveProgram` is 1590 (WRITEP). The
loader appends `.END.` as needed, calls `scanLabelsAndPrograms()`, then
`goToGlobalStep(...)`.

Programs live in `../c43/res/PROGRAMS/`: `.p47` are loadable, `.rtf` are the
human-readable exports. Ones we have used: `SPIRALk`, `BinetV4`, `GudrmPL`,
`MANSLV2`, `NQueens`, `TRIv1p14`, `GRAPHS`, `TSTPLOT`, `INTDEMO`, `OpAmp`,
`47DEFLT`.

## 5. `testPgms.bin` - the fixture whose absence fakes a dead subsystem

**Different format from `.p47`**: raw binary, size-prefixed, produced by the
native `generateTestPgms` target, not a `.p47` reader.

```bash
ninja -C build.sim testPgms
mkdir -p res/testPgms && cp build.sim/src/generateTestPgms/testPgms.bin res/testPgms/
```

`addTestPrograms()` (`config.c:1225`) reserves `TO_BYTES(TO_BLOCKS(24000))` and
`fopen`s `res/testPgms/testPgms.bin` **relative to the cwd**. It is called
unconditionally under `TESTSUITE_BUILD`.

If it is missing the suite prints `Cannot open file res/testPgms/testPgms.bin`,
leaves the program area empty, every `PGM=` test fails to resolve its label, and
**the entire program engine reads as dead in the coverage map**:

| File | Without fixture | With fixture |
|---|---|---|
| `decode.c` | 2.1% | **76.2%** |
| `lblGtoXeq.c` | 0.0% | **41.0%** |
| `nextStep.c` | 7.6% | **40.8%** |

Without the fixture those cases fail as pure artifacts, not defects. Generate it
from the **same synced upstream sources** as the binary, or the opcode numbering
will not match.

The fixture only loads into a blank calculator: `restoreCalc` returns early when
`loadTestPrograms` is set (`saveRestoreBackup.c:764`).

## 6. The test-authoring rules

### 6.1 Assert a computed value a broken implementation would get wrong

The single most important rule. A test
that ends `Out: EC=0` only proves the code did not error - it passes over
garbage. Every driver we shipped asserts the *value*: store/recall, compare,
matrix, distribution, curve-fit and predicate results by value; both roots +/-2
of `X^2-4`; the derivative of `X^3`; all five solved TVM variables; the
effective rate 125%.

**Test: if you deleted the function body and returned a plausible constant, the
test must fail.**

### 6.2 Never assert a default - the no-op bypass

The plausible constant a no-op returns is usually a **default**: a zero position
or count, an empty string, `EC=0`, or the seeded input left untouched. Never make
the expected value one of these when a distinctive alternative exists.

- Assert a **non-zero** `APOS?` position - search for a glyph that is not at
  index 0.
- Assert a **non-empty** rotate/shift result.
- Assert a length that **differs** from the seed.
- Assert the **specific non-zero** error code on an error path, not `EC=0`.

When no distinctive input exists - the operation is a genuine no-op on its input
(rotate/shift of an empty string), or its only effect is a headless display
(`42AVIEW`, `42PRA`, `42PROMPT`, `42APPEND` over the empty alpha buffer) - **do
not write the case at all.** Leave the branch uncovered and record why in the
residual. Deleting such a case lowers the coverage number but makes it honest
rather than padded.

### 6.3 Mutate between the action and the assertion

The most easily-missed hole; it recurred twice.

- **Restore/round-trip.** `covStateRoundtrip` saved the
  registers and loaded them back *without changing them in between*, so the
  losslessness assertion would have passed even if `fnLoad` were a no-op - it
  proved "not corrupted", not "restored from file". Fix: clobber with a sentinel
  (`covClobberRegs` writes -99999 into R00..R05) *after* the save and *before*
  the load, proving both value and datatype are restored.
- **Solve-for-a-pre-seeded-answer.** The TVM drivers seeded a *consistent*
  problem then "solved" for one variable - but the target already held the
  correct answer, so a no-op `fnTvmVar` would copy it to X and pass. Fix:
  overwrite the target with a deliberately-wrong value (50) before solving.

That fix exposed a second fact: the closed-form targets (FV/PV/PMT/N) recompute
from any wrong seed, but the **iterative I% solve reads the seeded register as
its starting guess** - seeding it with the exact answer meant the test only
confirmed 100 is a fixed point, never that the solver *finds* it. **For an
iterative solver the clobber must be wrong yet inside the convergence basin**
(50 -> 100 works; a far sentinel like 12321 makes the rate solver diverge).

### 6.4 Choose round-number problems so the expected value is exact

Do not lock in whatever the current build prints (that is a change detector, not
a test). Pick inputs whose answer is analytically exact and write *that*. TVM
used N=3, I%=100, PV=-1000, FV=8000 precisely so each solved variable is clean;
amortisation used a first period whose interest (1000), principal (200) and
balance (800) are exact. **An asserted value you derived by hand outranks one you
copied from output.**

### 6.5 Probe the binary, never guess

Build the headless testSuite, run a seeded probe file with **deliberately wrong**
expectations, capture the actual `Register .. should be .. but it is ..` output,
then encode the confirmed value. A guessed convention produces false failures -
the mpmath pass guessed the `cbrt` branch and the angle-mode tags and both were
wrong in the **generator**, not in c47.

Probing settled semantics no amount of reading would: `STO-` stores `reg - X` but
`RCL-` pushes `X - reg`; the `eq_cov` `=` residual is RHS-LHS (10-7=3), not
LHS-RHS.

### 6.6 Tests must be order-independent

Restore every non-default mode you set. A TVM driver that clears `FLAG_ENDPMT`
(BEGIN mode) or an amortization driver that leaves `FLAG_AMORT_HP12C` set leaks a
mode flag into every later test - a latent, position-dependent failure that can
reach ~150 cases downstream.

**Reset shared solver status, never OR into it.** `covDerivEq` leaves
solver-status bits set, so a later driver that ORs in `USES_FORMULA` inherits
them and fails "no root found" mid-suite while passing in isolation; assign,
don't OR. A prior TVM solve leaves `SOLVER_STATUS_TVM_APPLICATION` set the same
way, so a later `covSolvePgm` must clear it.

When a test genuinely cannot self-clean, document the ordering constraint where
the run order is defined - see the comment block at the tail of
`testSuiteList.txt` explaining why `matrix2_cov`, `clcvar_cov` and
`serialize_state_cov` must run after `programs`, and `serialize_cov` last.

Watch for mode-dependent readings: `fnGetType` folds the operand angular/polar
mode into the pushed code's fraction (a complex reads `2.000` in RECT but `2.300`
under an inherited degree mode), so pin `CM=RECT`.

### 6.7 Differential testing against an independent oracle

For numeric code, do not hand-assert transcendental values - generate them from a
trusted second implementation and diff. The `numeric_diff_cov` vectors come from
`mpmath` at 60 digits, rounded to 36, against the calculator's 34-digit real -
an oracle sharing none of its code. 135 cases; all pass, so c47's core math
matches mpmath to 30+ digits. The generator is RNG-free and byte-reproducible:

```bash
python3 scripts/test/tooling/numeric-vectors.py | diff - <(python3 scripts/test/tooling/numeric-vectors.py)
```

### 6.8 The pool + GMP gate is an invariant every test preserves

The suite's end-of-run assertion "the memory owned by GMP should be 0 bytes" is
not decoration - it is the leak gate, and `processTests` returns failure on it. A
new test that raises coverage but leaves GMP non-zero has introduced or exposed a
leak and is not done. Malloc-level ASan/LSan cannot see the `ram[]` pool
(the memory model in [04-debugging.md](04-debugging.md)), so this application-level accounting is the only gate that catches
pool leaks. Treat it as mandatory, not advisory.

### 6.9 Name test artifacts so they never touch real files

The headless suite reads and writes state, program, backup and register-dump
files. If those used the real filenames (`backup.cfg`, `c47.sav`,
`c47program.bin`, `c47state.bin`), running the suite on a device or a working
checkout would silently overwrite the user's saved state. The test HAL prevents
that by renaming every writable artifact with a `Test` suffix.

`src/testSuite/hal/io.c` is the single source of truth: every `ioPath*` case
returns a Test-suffixed name. A test never reads or writes a bare production
filename. Prefer the HAL paths - `fnSave`/`fnLoad`/`fnExportProgram` route
through `ioPath*` automatically. When a driver must touch a file directly (e.g.
`covLoadPgm` writes a program file then calls `fnLoadProgram`), it uses the exact
Test-suffixed name the HAL maps that `ioPath` to (`c47programTest.bin`) and says
so in a comment. **Re-check on every new file-touching driver: grep the diff for
`.bin` / `.cfg` / `.sav` / `.p47` literals and confirm each carries the suffix.**

### 6.10 Unobservable results - label the file a coverage driver

Some results are genuinely unobservable from the corpus and the honest move is to
say so, not to invent an assertion:

- `compare_cov`, `checkval_cov`, `fnIsPrime`: the boolean lands in
  `temporaryInformation`, not a register.
- `error_cov`: asserts the raised error code - which for error-branch tests *is*
  the correctness check.
- `saverestore_cov`: file I/O whose only headless-observable result is the exit
  code.
- `mathspecial_cov`: the `inf` input is rewritten to 9e9999 by the parser, so it
  exercises the overflow path, **not** `isInfinite()` - the file comment
  discloses this.
- LU/QR: pivoted factors are implementation-specific, not a stable target.

**Do not add tests that execute code without assertions unless the test is purely
a sanitizer/fuzz harness and says so explicitly.**

## 7. Method discipline

### 7.1 Force a clean rebuild before you trust a numeric anomaly

An incremental build is not trustworthy evidence for a numeric claim. ninja can
fail to recompile a changed translation unit, so the binary runs old object code
and a value looks wrong when the source is fine. **Before filing or acting on any
value anomaly, `touch` the owning translation unit (or wipe the build dir) and
re-run.**

### 7.2 Hostile-audit every candidate fix before you trust it

**A patch you wrote is a suspect, not a solution.** Before committing any fix,
attack it as its own adversary; a failure on any one front means the fix is not
done, however plausible it reads:

- **Root cause, not a story that fits.** Prove the fix addresses the *actual*
  origin, not an explanation that merely sounds right. An uninitialised-read
  finding blamed on an unzeroed array is worthless if `--track-origins` shows
  the value is created in a different function - the array change would remove
  nothing. Name the mechanism and show it, or the fix is a guess.
- **The repro must fire without the fix.** A clean result proves nothing until
  the negative control shows the bug on the unfixed tree (7.7). Green can mean
  the repro never exercised the path - a single-op repro that misses the
  trigger, or a binary that was never rebuilt.
- **Blast radius.** Trace every other reader and writer the change touches -
  save/restore round-trips, sibling call sites, persisted state - and *prove*
  they are unaffected against a genuine before/after, not assume it. `git stash`
  does not revert a committed change, so a "master" build that still carries the
  fix compares nothing; revert in the work tree and rebuild.
- **The same class elsewhere.** Grep for the pattern; a one-site fix usually has
  copies (7.8).

This includes the tests the fix ships with: review the branch as devil's
advocate - "what would make this test pass even though the code is broken?" - and
land any hardening as its own documented commit so the review is traceable
rather than silently amended.

The hostile-audit is not optional and not a formality: on this codebase, fixes
have been committed on a misread root cause, "verified" from a repro that never
fired, and signed off against a comparison that silently tested the fix against
itself. The hostile-audit is what catches each before it ships.

### 7.3 Report honestly - retract what you cannot prove

**A fix goes in only with a proven root cause; an unconfirmed anomaly is
documented, not patched; a mistaken report is retracted in the record.** A test
that asserts a wrong value hides the defect it should catch.

### 7.4 Never silently cap - log what a scan skipped

If a scan bounds its work (top-N, sampled, no-retry, a whitelist that hides
unregistered functions), say so in output. Silent truncation reads as "everything
passed" when it means "everything we looked at passed". Make the boundary visible
so a reader knows what was *not* tested.

### 7.5 A harness is code under test

The fuzz/leak lanes carry their harness as a patch applied onto synced upstream.
**After editing any carried `.patch`, apply it and compile the result before
committing** - never trust a patch by inspection. A hunk header whose line count
no longer matches its body makes `git apply` truncate the file at the wrong
brace, and the build breaks. Long-lived `test/*` branches drift behind upstream;
rebase on every upstream resolve.

### 7.6 Baselines ratchet one way

Leak, warning, valgrind, cppcheck and coverage lanes gate against a checked-in
baseline that may shrink (a fix) but **never silently grow**. When a baseline must
move because upstream changed, resync it in its own commit that names the
upstream SHA, and record what each line represents (e.g. the
`keyscan CRASH seq=integrate_pgm_x20` entry) so a future reader can tell a
known-issue marker from a regression.

### 7.7 Negative controls make a gate credible

**A gate you have never seen fail is not known to work.** Before trusting one,
inject the fault it is meant to catch and confirm it reports: an `item=999`
leak, a growth case, a sector drop below the floor, an `Invalid read` at a known
line, a deliberately broken patch. A matcher that never fires because its own
trigger is wrong passes everything silently (04-debugging Section 12).

### 7.8 Fixes get copy-pasted - grep the class

A boundary bug rarely lives in one place. When you fix one, grep the codebase
for the same pattern before calling it done: the same guard is often duplicated
across files (`decode.c`, `addons.c`, `lblGtoXeq.c`, `programmableMenu.c` all
decode program bytes), a helper written to centralise it can carry the same
error, and two fixes with inconsistent bounds (`programRegionEnd` vs
`firstFreeProgramByte`) leave a gap between them.

Corollaries:

- **A guard placed after the dereference is not a guard.** A region check that
  runs *after* an out-of-bounds `indexOfItems[op]` read validates nothing.
- **When the buffer is undersized for legitimate input, the buffer is the bug.**
  A global label can be 255 bytes; readers used 15/16-byte buffers, so clamping
  to the buffer would silently truncate a real name. Size the buffers.
- The credible sweep also names its **negative controls**:
  `manage.c:559 baseChars[lastIntegerBase*2]` is indexed by a runtime mode value
  bounded 2..16, not program data; `decode.c:268` worst-case index is 2442 <
  LAST_ITEM. Checking those is what makes "every copy is covered" believable.

---