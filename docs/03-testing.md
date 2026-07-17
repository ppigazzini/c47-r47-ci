# Testing c43

How to drive the calculator and how to write a test that actually tests. The
detectors - leak scanning, the pool canary, fuzzing, Valgrind - and the
false-pass catalogue are in [04-debugging.md](04-debugging.md). The lane scripts
that run all of this in CI are in [05-ci.md](05-ci.md).

## The one-line version

```bash
make test     # 12065 pass / 6 fail is the healthy baseline
```

Six failures is correct on a clean upstream tree. **Compare the failure set
against master, never the count.** A lane that reports "6 failures" proves
nothing on its own; two of those six have moved before.

## The three ways to drive it

| driver | what it is | use it when |
|---|---|---|
| `testSuite` | the corpus runner: reads `.txt` files, calls functions directly | asserting a computed value |
| `t47` | the `r47` simulator plus a Jim/Tcl DSL, headless | you need state set up, a program run, or a register read |
| `c47` under `xvfb-run` | the real GTK simulator, real key presses | the path is only reachable through the keyboard or a menu |

The corpus never touches the keyboard, the menus, or the screen. Anything
reached only through those is verified by human inspection unless you drive the
GTK binary yourself.


Four drivers, ascending in realism and descending in convenience. Pick the least
realistic one that can reach the bug.

## 1. Headless testSuite (the corpus)

```bash
cd ~/_git/c43
meson setup build.sim --buildtype=custom -DRASPBERRY=`tools/onARaspberry` -DDECNUMBER_FASTMUL=true
ninja -C build.sim src/c47/vcs.h                       # ALWAYS first, see hazard 22.8
ninja -C build.sim src/testSuite/testSuite
./build.sim/src/testSuite/testSuite src/testSuite/tests/testSuiteList.txt
```

Corpus size as of upstream `master` on 2026-07-16: **323 test files in
`src/testSuite/tests/`, 317 listed** in `testSuiteList.txt`. (Both numbers move;
re-count rather than quoting this line.)

- The corpus grammar is documented in the header comment of
  `src/testSuite/tests/testSuiteList.txt` - **that comment is the authority**,
  not this page. Directives: `Func:`, `Item:`, `In:`, `Out:`, `Desc:`,
  `Desc_prefix:`, `Desc_suffix:`, `Timer:`. Register types
  `LonI Stri ShoI Real Cmpx Time Date ReMa CxMa`. `FARG=n` is the `uint16_t`
  passed to the function. `PGM="Name"` selects a global label for
  `Func: fnExecute`. Matrices are `"M2,2[1,2,3,4]"`; `any` / `?` skip an element.
- `Func:` resolves against the `funcTestNoParam[]` whitelist
  (`testSuite.c:75-637`), **not** the item catalog - see the coverage section of [04-debugging.md](04-debugging.md).
- `Item:` (`testSuite.c:4311`) drives the **real dispatch chain**
  (`reallyRunFunction`), unlike `Func:` which calls the handler directly. It
  accepts an `ITM_` name resolved by parsing `src/c47/items.h` at runtime, so it
  cannot go stale. Prefer `Item:` when the undo/stack-lift wrapper is part of
  what you are testing.
- `abortTest()` counts a failure and continues (its `exit(-1)` is commented
  out), so one bad case never stops the run. This makes the corpus a good
  carrier for assertion-style tests.
- The test HAL `src/testSuite/hal/io.c` maps every writable path to a
  **Test-suffixed** name (`backupTest.cfg`, `c47Test.sav`, `c47programTest.bin`,
  `c47stateTest.bin`, `c47regdumpTest.txt`). See rule 6.9 below.

## 2. t47 - the headless scripted simulator (the workhorse)

`t47` is **not a separate program**: it is a copy of the `c47` or `r47` GTK
binary built into `build.sim.t47` with `-DT47`, which only silences debug output
(`defines.h:400-439`). Headless is selected by **the binary's basename**
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

`item 44 I` is STO I (verified live: the sim echoes
`Calling catalog function STO(J), index 44`).

**The result depends on the branch, and that is the control.** On upstream
`master` this prints `I=1 J=1` - `fnEditMatrix` (`ui/matrixEditor.c:91-92`)
unconditionally does `setIRegisterAsInt(true,0)`/`setJRegisterAsInt(true,0)`,
which store I=1/J=1 (`asArrayPointer=true` increments), and nothing restores
them. Where the editor keeps its cursor off the user's registers it prints
`I=7 J=9`. Drop `item 1529` and I/J survive on both.
**Check which branch is checked out before reading any result** - a "clean"
result may mean the fix is applied, not that the bug is absent.

Two real bugs found this way, both initially misdiagnosed as pool corruption:

- **The matrix editor clobbers I/J.** SPIRALk reads I as scaling factor and J as
  growth rate with **0 as the "use default" sentinel**, so merely *opening* the
  editor makes radius = I*e^(J*angle) hit the program's limit after ~0.8 turns
  instead of ~9.65 - the "totally wrong graph". A register collision, not
  corruption. The battery proved everything else preserves I/J
  (det/transpose/invert/M.LU/M.QR/M.GETM/M.PUTM/RCLEL/STOEL/M.DIM/M.INSR/
  M.DELR/SIM_EQ all return 7/9); only M.EDIT and its `Mat_A`/`Mat_B`/`Mat_X`
  wrappers, plus INDEX (whose purpose it is), write them.
- **STOVEL/RCLVEL/STOVEC/RCLVEC decrement I and J by 1 on every call.** The
  save/restore idiom saves 0-based (`getIRegisterAsInt(true)` does `ret--`) and
  restores raw (`setIRegisterAsInt(false, iBak)`), so `STOVEL_1` x1 gives
  I=6 J=8, x3 gives I=4 J=6, x9 gives I=-2 J=0. Walking I to exactly 0 flips
  SPIRALk's sentinel back to defaults, so the symptom is intermittent.
  **Matching the convention is not the fix.** The backup is an `int16_t`, so it
  cannot carry a register whatever the convention: I=0.35 comes back -1,
  I=99999 comes back -31074, a complex 3+ix4 comes back as the long integer -1.
  The value is truncated before the restore runs. An integer sentinel hides this
  entirely - **probe 0.35 and 99999, not just 7 and 9**. The fix is to stop
  writing the registers, not to write them back better.

Two "clobbers" the same battery flagged are **by design - do not fix them**:
FACTORS (1477) rolls G<-H<-K deliberately (commit `6879c1562`, "Storing the last
three factors in G, H, K"), and monadic XFN zeroes T/A/B because XFN owns six
registers as two triples. Safe spare registers for user-program parameters are
**E, F, O, U, V, W** only.

## 3. GTK simulator under xvfb (when only a real key press will do)

Needed when the path is reachable only through the keyboard/menu layer: the
matrix editor (MIM), program editor (PEM), equation editor (EIM), TAM parameter
entry.

```bash
cd ~/_git/c43            # MUST run from the repo root: res/ CSS is cwd-relative
xvfb-run -a ./c47 --reset --exec 'press 1; press ENTER; puts "X=[reg X]"'
```

- `gtk_init` runs unconditionally (`c47-gtk.c:428`), so a DISPLAY or `xvfb-run`
  is required **even headless**.
- The repo root is mandatory for the GUI: `prepareCssData()` (`gtkGui.c:1974`)
  does `fopen(CSSFILE, "rb")` on `res/c47_pre.css` and calls `exit(1)` on
  failure. `res/testPgms/testPgms.bin`, `backup.cfg`, `PROGRAMS/`, `STATE/`,
  `DATA/` are cwd-relative too.
- **`press` takes ONE key per call** (`press 1; press ENTER`), or a Tcl list.
  Not registered headless because `scriptInjectGtkKey` needs a realized window.
- Tokens: `F1`..`F6` (softkeys); `@f` / `@g` (shift toggles); `@k NN`; a single
  ASCII char; `ENTER`/`Return`; `R/S`.
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

and the suite goes 9834 pass / 6 fail -> 9840 pass / **0 fail**. Those six
"failures" were pure fixture artifacts. Generate the fixture from the **same
synced upstream sources** as the binary, or the opcode numbering will not match.

The fixture only loads into a blank calculator: `restoreCalc` returns early when
`loadTestPrograms` is set (`saveRestoreBackup.c:762`).

---

These rules were each learned from a shipped commit. Their foundation is the
upstream-merged CLI/math coverage corpus (MR !1487, merge `8468e529a`, "expand
CLI/math coverage corpus with wrong-answer assertions"), which established the
`covXxx` driver pattern, the wrong-answer assertion style, the mpmath
differential vectors and the fixture-ordering discipline. Where a rule cost us a
mistake, the mistake is named so it is not repeated.

## 6. The test-authoring rules

### 6.1 Assert a computed value a broken implementation would get wrong

The single most important rule, and the founding principle of MR !1487. A test
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
residual. The stringFuncs review deleted eight such cases, taking the number from
96.76% to a **true 93.23%** - honest rather than padded.

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

Restore every non-default mode you set. `covTvmPmt` left `FLAG_ENDPMT` cleared
(BEGIN mode) and `covAmort` left `FLAG_AMORT_HP12C` set, leaking a mode flag into
~150 later tests. A leaked global is a latent, position-dependent failure.

**Reset shared solver status, never OR into it.** `solve_cov` passed in isolation
and failed mid-suite ("no root found") because `covDerivEq` leaves solver-status
bits set and `covSolveRoot` OR'd in `USES_FORMULA`; assign, don't OR. Likewise
`covSolvePgm` failed because a prior TVM solve leaves
`SOLVER_STATUS_TVM_APPLICATION` set.

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
checkout would silently overwrite the user's saved state. The maintainer fixed
exactly this on MR !1487, renaming every artifact with a `Test` suffix.

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

Our worst mistake this cycle: `fnTvmVar(FV) = -613.91` was reported as a likely
bug. It was a **stale build** - ninja had not recompiled `tvm.c`, so the binary
ran old object code (`tvm.c` was byte-identical between the branch base and
master). `touch src/c47/solver/tvm.c` and rebuild gave the correct 1628.89.
**Before filing or acting on any value anomaly, `touch` the owning translation
unit (or wipe the build dir) and re-run.** An incremental build is not
trustworthy evidence for a numeric claim.

### 7.2 Adversarial self-review is required, not optional polish

Reviewing the branch as devil's advocate - "what would make this test pass even
though the code is broken?" - is what surfaced 20.2 and 20.3 *after* the tests
were green and committed. Budget a dedicated pass whose only job is to attack the
tests, and land the hardening as its own documented commit so the review is
traceable rather than silently amended.

### 7.3 Report honestly - retract what you cannot prove

Two findings did not survive scrutiny: the TVM "bug" (21.1, a stale build -
retracted) and an `integrate` parser anomaly that was real but not root-caused
(aliasing, progress-display and OOB all ruled out; ASan+UBSan clean, so an
in-bounds stale read - a logic bug, not memory unsafety). The latter was left
documented and **unshipped** rather than papered over with a guess, and only
manifested through the harness's shortcut setup, so it was never established that
the real keyboard path was affected. It was later confirmed fixed upstream.

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
A comment edit that changed a new-file hunk's line count made `git apply`
truncate the file at the wrong brace and the build broke.
**After editing any carried `.patch`, apply it and compile the result before
committing** - never trust a patch by inspection. Keep hunk headers honest when
hand-editing. Long-lived `test/*` branches drift (they have been 117-138 commits
behind); rebase on every upstream resolve.

### 7.6 Baselines ratchet one way

Leak, warning, valgrind, cppcheck and coverage lanes gate against a checked-in
baseline that may shrink (a fix) but **never silently grow**. When a baseline must
move because upstream changed, resync it in its own commit that names the
upstream SHA, and record what each line represents (e.g. the
`keyscan CRASH seq=integrate_pgm_x20` entry) so a future reader can tell a
known-issue marker from a regression.

### 7.7 Negative controls make a gate credible

Every gate we trust has been proven to fire: an injected `item=999` leak, an
injected growth case, a simulated sector regression (17% -> 5%), a synthetic
`Invalid read of size 8 @ stack.c:42`, a deliberately-broken patch. **A gate you
have never seen fail is not known to work** - the valgrind matcher was inert for
its whole life precisely because nobody had tested that it could fire (hazard
22.15).

### 7.8 Fixes get copy-pasted too - grep the class

The decoder boundary fix landed in `decode.c` only; three copies (`addons.c`,
`lblGtoXeq.c`, `programmableMenu.c`) kept the pre-fix guard. A *new* helper,
`boundProgramNameLength`, reproduced the very bug it was written to fix. And
inconsistent bounds between two fixes create the gap (`programRegionEnd` vs
`firstFreeProgramByte`).

Corollaries from the same sweep:

- **A guard placed after the dereference is not a guard.** `findKey2ndParam` was
  "hardened" with a region check that runs *after* the out-of-bounds
  `indexOfItems[op]` read.
- **When the buffer is undersized for legitimate input, the buffer is the bug.**
  A global label can be 255 bytes; readers used 15/16-byte buffers, so clamping
  to the buffer would silently truncate a real name. Size the buffers.
- The credible sweep also names its **negative controls**:
  `manage.c:559 baseChars[lastIntegerBase*2]` is indexed by a runtime mode value
  bounded 2..16, not program data; `decode.c:268` worst-case index is 2442 <
  LAST_ITEM. Checking those is what makes "every copy is covered" believable.

---