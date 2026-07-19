# The c43 Codebase

A map of the upstream c43 source tree: what the folders hold, what the modules
are, how a build is produced, and how the parts connect at run time. Read it
when you need to find something, or to understand what you found.

The product source is not in this repository. Clone it first:

```bash
git clone https://gitlab.com/rpncalculators/c43.git
```

Verified against upstream `master` at commit
`33328e4cc25588eb7504f38f4076f8feae3ae766` (2026-07-18). Every count on this
page was measured at that commit; re-measure before relying on one. Line counts
are blob lines, not SLOC: an upper bound, useful for relative scale only.

## 1. What this page does not cover

Three other documents own their subjects. This page points to them rather than
restating them, so each fact has one source.

| subject | owner |
|---|---|
| Physical architecture, the link graph, dependency metrics | [00-architecture.md](00-architecture.md) |
| The build targets, Meson graph, packaging | [02-build.md](02-build.md) |
| Writing and running tests | [03-testing.md](03-testing.md) |
| Detectors and the false-pass catalogue | [04-debugging.md](04-debugging.md) |

Use [00-architecture.md](00-architecture.md) for anything about the dependency
graph, cycles, ACD/NCCD, the item table's structural cost, or the god header.
Those numbers are not re-derived here; that page owns them. Counts move with
upstream, so re-count against a live clone before quoting one rather than
trusting a figure written down here.

## 2. The product and its targets

C47 is a high-precision RPN scientific calculator for the SwissMicros DM42
family, descended from WP43. The repository is named `c43` and the application
it builds is C47; `README.md:9` records the chain WP43S -> WP43 -> WP43C -> C43
-> C47 and warns that prior names persist throughout the source.

The source directory is `src/c47`.

One library, several targets:

| target | what it is |
|---|---|
| `c47`, `r47` | GTK 3 desktop simulator, two keyboard layouts |
| `C47.pgm`, `C47_qspi.bin` | DM42 firmware (DMCP, Cortex-M4) |
| `C47.pg5`, `R47.pg5` | DM42n/DM32 firmware (DMCP5, Cortex-M33) |
| `testSuite` | corpus runner, no window, no hardware |
| `t47` | the `r47` simulator built with `-DT47`, driven by a Jim/Tcl DSL |
| `generateConstants`, `generateCatalogs`, `generateTestPgms`, `ttf2RasterFonts`, `forcecrc32` | build-time generators |

`R47` is not a platform. It is a keymap and model variant of the same sources,
selected with `-DCALCMODEL=USER_R47` (`src/c47-gtk/meson.build:84`,
`src/c47-dmcp/meson.build:183`) and shipped with `res/keymaps/keymap_R47.bin`.

### 2.1 What differs between the targets

One library, four adapter sets, six shipped binaries. They differ by
preprocessor define, by which HAL adapter they link, and by how much of the
input stack they exercise:

| | GTK sim (`c47`/`r47`) | `t47` | `testSuite` | DMCP / DMCP5 firmware |
|---|---|---|---|---|
| define | `PC_BUILD` | `PC_BUILD` + `T47` | `PC_BUILD` + `TESTSUITE_BUILD` | `DMCP_BUILD` (+ `OLD_HW`/`NEW_HW`) |
| HAL adapter | `src/c47-gtk/hal/` (5 files) | same as GTK | `src/testSuite/hal/` (5 files) | `src/c47-dmcp{,5}/hal/` (4 files; the SDK supplies the LCD) |
| entry | `c47-gtk.c` | `c47-gtk.c` | `testSuite.c` | SDK `startup_pgm.s` |
| driven by | keys and menus | Jim/Tcl DSL (`readp`, `xeq`, `item`, `reg`, `press`) | a `.txt` corpus, calling functions directly | keys |
| keyboard/menu layer | yes | only with a window (`press` is GTK-only) | no | yes |
| pool size | 65534 blocks | 65534 | 65534 | 16384 (DM42) / 65534 (DM42n) |
| links GTK | yes | yes | **yes** - see below | no |

Three consequences worth knowing before choosing a harness:

- **The DMCP adapters are the small ones, and that is backwards.** The port is
  SwissMicros' own API, so on DM42 there is nothing to adapt - the SDK is the
  implementation. Every other target emulates the DM42 instead
  ([00-architecture.md](00-architecture.md) s5.1).
- **The testSuite links GTK even though it has no GUI.** The library defines GTK
  callbacks inside itself (`screen.c`), so every target that links the library
  links GTK. The testSuite's `hal/gui.c` is stubs and its `hal/lcd.c` renders to
  a buffer; it is display-less, not GTK-less ([00-architecture.md](00-architecture.md) s5.4).
- **`t47` is the `r47` build, not a separate program.** `T47` is consumed at one
  place, `defines.h:419`, which `#undef`s the DM42/monitor/debug options. Its
  DSL lives in `src/t47/` and is linked into the simulator through `t47_dep`.
  `press` is registered only when a window exists, so keyboard-level tests need
  the GTK binary under xvfb ([04-debugging.md](04-debugging.md) s9).

Scale at `33328e4cc`: 13804 commits; 525 tracked `.c`/`.h` files totalling
179885 lines; 229 `.c` in the library; 322 corpus tests; 15 `meson.build` files.

## 3. Repository map

Top level:

```
  src/          the code
  res/          runtime resources shipped with the app
  dep/          vendored decNumber, SDK submodules, jimtcl, forcecrc32
  subprojects/  one meson wrap: gmp-6.2.1 (cross builds only)
  docs/         doxygen/sphinx config and the appnote PDFs
  tools/        build helper scripts
  PROGRAMS/     keystroke program sources (.txt)
  LIBRARY/      C47.dat
  Makefile meson.build meson_options.txt .gitlab-ci.yml BUILD.md README.md
```

`src` by area at `33328e4cc`, `.c`/`.h` only. **Each row counts that directory
alone, not its subdirectories** - so `src/c47-gtk` excludes `src/c47-gtk/hal`,
which has its own row. [00-architecture.md](00-architecture.md) s2 counts recursively, which is
why its figures for those directories are larger; the facts agree, the method
differs.

```
  area                             files    lines
  src/c47/(root)                      81    71003   <- 46% of the library
  src/c47/mathematics                257    44230
  src/c47/solver                      18    10180
  src/c47/c47Extensions               19     9813
  src/c47-gtk                          4     7415
  src/c47/programming                 15     5877
  src/testSuite                        2     4809
  src/generateTestPgms                 1     4245
  src/c47/distributions               33     4237
  src/c47/ui                           6     3544
  src/c47/printing                     4     3409
  src/t47                              8     2666
  src/t47/jimgen                       6     1236
  src/c47/browsers                     9     1083
  src/c47/logicalOps                  23     1072
  src/generateConstants                1      960
  src/c47-gtk/hal                      5      826
  src/c47-dmcp/hal                     4      568
  src/c47-dmcp5/hal                    4      568
  src/ttf2RasterFonts                  2      536
  src/c47/hal                          5      497
  src/c47/core                         2      393
  src/testSuite/hal                    5      285
```

Three directory names do not describe their contents. This is called out in
[00-architecture.md](00-architecture.md) s2 and repeated here only because it
misleads navigation:

- `core/` is `freeList.c` + `freeList.h`. An allocator, not a core.
- `ui/` is `matrixEditor.c`, `tam.c`, `tone.c` and headers. The real user
  interface (`screen.c`, `display.c`, `keyboard.c`, `softmenus.c`,
  `statusBar.c`) is in the root.
- `hal/` is 5 headers and no `.c`. That one is deliberate (Section 8).

### 3.1 The flat root, module by module

39 `.c` files, 38 of them compiled, holding 46% of the library. There is no
subdirectory for display, input, persistence or state, though each exists as a
concept and each has several files. Grouped by the concept they belong to:

| module | lines | what it is |
|---|---|---|
| **dispatch** | | |
| `items.c` | 4734 | `indexOfItems[]`, `runFunction`, `reallyRunFunction`. The command set (Section 5) |
| `calcMode.c` | 282 | mode transitions only, not the modes themselves |
| **input** | | |
| `keyboard.c` | 4987 | key resolution, shift state, `processKeyAction`, `executeFunction`, `fnKeyExit` |
| `assign.c` | 1282 | `kbd_std_*[37]` layout tables per model, `kbd_usr[]`, ASSIGN mode |
| `bufferize.c` | 2789 | the NIM/AIM buffer and the number-entry state machine, `closeNim` |
| **display** | | |
| `screen.c` | 6623 | `refreshScreen`, the per-mode refreshers, the GTK draw callback |
| `display.c` | 4012 | formatting a value into a register line |
| `softmenus.c` | 4428 | `softmenu[]`, the stack, static and dynamic menus |
| `statusBar.c` | 1098 | the status bar |
| `fonts.c` | 145 | glyph lookup; the raster data is generated |
| `fractions.c` | 629 | fraction display mode |
| **state** | | |
| `c47.c` | 1258 | the globals live here, plus start-up |
| `config.c` | 2228 | boot, reset, CONFIG, the `ram` allocation and pool seeding |
| `registers.c` | 2416 | register accessors, `allReservedVariables[]`, local registers |
| `registerValueConversions.c` | 1570 | the only sanctioned bridge between representations |
| `realType.c` | 126 | `real_t` helpers over decNumber |
| `stack.c` | 428 | the RPN stack, `liftStack`, `_Drop`, `saveForUndo`, `undo` |
| `flags.c` | 862 | system and local flags |
| `memory.c` | 209 | pool accounting over `core/freeList.c`; GMP hooks |
| `error.c` | 397 | `displayCalcErrorMessage`, `errorMessages[]` |
| **values** | | |
| `store.c` | 702 | the STO family, STOEL/STOIJ |
| `recall.c` | 585 | the RCL family, RCLEL/RCLIJ |
| `constants.c` | 59 | pushes a generated constant |
| `integers.c` | 784 | short-integer operations |
| `charString.c` | 1279 | UTF-8 string helpers |
| `stringFuncs.c` | 1483 | user-facing string functions |
| `sort.c` | 192 | sorting helpers |
| `dateTime.c` | 1224 | date and time types |
| `conversionUnits.c` | 1258 | unit conversion |
| `conversionAngles.c` | 689 | angular conversion |
| **statistics** | | |
| `stats.c` | 1061 | the sigma sums |
| `curveFitting.c` | 1346 | regression |
| `plotstat.c` | 2147 | statistical plotting, `CM_PLOT_STAT`, `CM_LISTXY` |
| **persistence** | | |
| `saveRestoreCalcState.c` | 2793 | `.s47` state |
| `saveRestoreBackup.c` | 1484 | `backup.cfg`, simulator only |
| `saveRestorePrograms.c` | 602 | `.p47` programs |
| **other** | | |
| `timer.c` | 819 | the timer application, `CM_TIMER` |
| `debug.c` | 584 | debug helpers |
| `reservedRegisterLookupGenerator.c` | 85 | **not compiled** - absent from `src/c47/meson.build` |

The four hottest files in the repository - `items.c`, `softmenus.c`,
`keyboard.c`, `screen.c` - are all here, and all are dispatch, input or
presentation. See [00-architecture.md](00-architecture.md) s7 for the churn measurement.

`src/index spreadsheet/` (note the space in the name) holds design sources as
binary `.xlsx`: keyboard layouts, CONFIG defaults, unit conversions, item
indices. Their relationship to the code differs per file and is worth knowing
before trusting either:

- `res/fonts/sortingOrder.xlsx` is a **real build input**. `ttf2RasterFonts`
  shells out to `xlsxio_xlsx2csv` to read it
  (`src/ttf2RasterFonts/ttf2RasterFonts.c:338`), which is why CI builds xlsxio
  from source.
- `items3.xlsx` is **not** a build input. `items.c:1777` and `items.h:8` both
  say the table is "generated (**manually**)" from it. `items.c` is
  hand-maintained and is the source of truth;
  `tools/create items spreadsheet.py` runs the other way - it reads `items.c`
  and `items.h` and writes a TSV - and no build file references it.
- The keyboard layout tables carry "Do not change manually"
  (`src/c47/assign.c:6`) but no in-tree script converts the spreadsheet to
  `kbd_std_C47[]`.

So the spreadsheets are a mix of one automated input and several hand-transcribed
design sources. The transcribed ones have neither diffable provenance nor any
check that code and spreadsheet still agree.

## 4. How a build is produced

[02-build.md](02-build.md) owns the build and CI audit. This section
records only the mechanics needed to navigate the tree.

The `Makefile` is the user-visible contract; meson and ninja are the machinery.
The build directory is a variable, not a target property (`Makefile:11-12`),
overridden per target:

| make target | build dir | produces |
|---|---|---|
| `sim` / `simc47` | `build.sim` | `./c47` |
| `simr47` | `build.sim` | `./r47` |
| `t47` | `build.sim.t47` | `./t47`, a copy of the `r47` build |
| `test` | `build.sim` | runs the corpus (cleans first) |
| `dist_linux` | `build.rel.debug` | `c47-linux.zip` |
| `dist_macos`, `dist_windows` | `build.rel` | `c47-macos.zip`, `c47-windows.zip` |
| `dist_dmcp` | `build.dmcp.p<N>` | `c47-dmcp-pkg<N>.zip` |
| `dist_dmcp5`, `dist_dmcp5r47` | `build.dmcp5` | `c47-dmcp5.zip`, `r47-dmcp5.zip` |

`make t47` alone resolves to `t47: simr47` (`Makefile:117`), so `./t47` is the
R47 build. `T47` is consumed only at `src/c47/defines.h:419`, which `#undef`s the
DM42/monitor/debug options: a quiet variant, not a separate program.

### The generator pipeline

Four generators run as meson `custom_target`s and feed the library. They are
`build_by_default: false` and run only because the sim, testSuite and firmware
targets list their outputs in `sources`:

```
  res/fonts/*.ttf ---> ttf2RasterFonts ---> rasterFontsData.c ---+
  sortingOrder.xlsx --^  (via the external xlsxio_xlsx2csv)      |
                                                                 |
                     rasterFontsData.c must exist first          |
                                  |                              |
                                  v                              |
                        generateCatalogs ---> softmenuCatalogs.h-+
                                                                 |
  generateConstants ---> constantPointers.{c,h}, ...2.c ---------+
                                                                 |
                                                                 v
                                                        the build dir
                                                                 |
                          +--- make's install -C (NOT ninja) ----+
                          v                                      |
                  src/generated/  ......shadows.....>  c47 / r47 / testSuite
                  (gitignored)     (it is on the include path AHEAD of the
                                    build dir - see below)

  generateTestPgms ---> testPgms.bin ---> res/testPgms/
  generateTests.py ---> src/testSuite/tests/conversions.txt  (into the SOURCE tree)
```

Two edges bite. Fonts must be rasterized before catalogs, because
`generateCatalogs` links `rasterFontsData.c`
(`src/generateCatalogs/meson.build:3`). And the `install -C` loop back into
`src/generated/` is the shadowing trap, below.

`ttf2RasterFonts` shells out to `xlsxio_xlsx2csv` on
`res/fonts/sortingOrder.xlsx` (`src/ttf2RasterFonts/ttf2RasterFonts.c:338`).
This is the only use of xlsxio in the tree and it is a runtime dependency on the
binary, not a meson `dependency()`. It is why CI clones and builds xlsxio from
source (`.gitlab-ci.yml:38-40`). A spreadsheet is a build input.

### src/generated is not what it looks like

`src/generated/` is gitignored: `.gitignore:50` ignores `/src/generated/*` and
only `README.md`, `constantsVerification.txt` and `version.h` are tracked. The
other files appear locally because `make sim` copies them out of the build dir
(`Makefile:98-102`):

```
  install -C build.sim/src/generateCatalogs/softmenuCatalogs.h   src/generated/
  install -C build.sim/src/generateConstants/constantPointers.h  src/generated/
  ...
```

`src/c47/meson.build:245` sets
`c47_inc = include_directories('.', '../generated')`, so the source
`src/generated/` is on the include path alongside the build-dir copies. A stale
copy shadows a freshly generated header. [04-debugging.md](04-debugging.md) Section 12 records the
failure mode and the remedy.

## 5. The spine: one library, one header, one table

Three facts explain most of the codebase's shape.

**`src/c47/c47.h` is a bundle, not an API.** 639 lines, 134 `#include`
directives, 345 `extern` declarations. 228 of the 229 `.c` files under `src/c47`
include it, and for most it is the only project header they include. Every
translation unit therefore sees every declaration. The consequences - no
encapsulation, no compiler-checkable layering, no unit-test isolation, and why
the god header is load-bearing rather than merely untidy - are measured in
[00-architecture.md](00-architecture.md) s3 and s8.

**`indexOfItems[]` is the command set.** `item_t` (`typeDefinitions.h:603-615`)
carries a function pointer, a parameter, a catalogue name, a softmenu name, a
TAM argument range and packed status bits. `LAST_ITEM` is 2870
(`items.h:2989`), so the table has 2871 slots. Keys, menus, catalogues, programs
and the corpus all address commands by item number: `softmenus.c` never names a
maths function, it names item numbers. This is the codebase's best structural
idea, and because `func` is a function pointer it is also the edge that makes
every file reachable from every other ([00-architecture.md](00-architecture.md) s4, s8.3).

The `status` field packs six independent concerns into one `uint16_t`
(`defines.h:1040-1096`): stack lift after execution (`SLS_*`), undo behaviour
(`US_*`), catalogue membership (`CAT_*`), Equation Input Mode legality
(`EIM_*`), the parameter type when programmed (`PTP_*`), and the hourglass
(`HG_*`). Reading a row means decoding all six.

`MNU_*` ids are item indices too. They live in the same flat numbering space as
`ITM_*` in `items.h`, and a menu's row in `indexOfItems[]` supplies its label
through `itemSoftmenuName` while its `func` is never called. The minus sign in
`showSoftmenu(-MNU_x)` is an API convention, not a property of the id.

**`items.c` is hand-maintained.** Its own header says the table is "generated
(manually)" from a spreadsheet. Do not look for a generator: the only related
tool reads `items.c` and exports a TSV. The catalogues, by contrast, are
genuinely build-generated into `src/generated/softmenuCatalogs.h` by
`generateCatalogs`.

### 5.1 The functions

Every command is a row in the table and a function behind it. The convention is
uniform and worth internalising:

```c
  void fnSomething(uint16_t param);      // EVERY command has this signature
```

One `uint16_t` in, `void` out. Results go to the stack or a register; errors go
to the global `lastErrorCode`. There is no return value and no error return
anywhere in the command set. 906 distinct such functions are defined under
`src/c47` -- `git grep -hoE '^ *void +fn[A-Za-z0-9_]+ *\(uint16_t' -- 'src/c47/**/*.c'`,
deduplicated by name. The figure moves with the method: 810 of them are actually
named in the `func` field of `indexOfItems[]`, the rest being helpers and
not-yet-bound entry points.

The `param` is the second half of the mechanism. It comes from the table row -
`indexOfItems[func].param` - unless TAM supplied one (Section 10). That is how
one C function serves many items: `fnStore` is the function for `STO`, and the
row's `param` distinguishes `STO+`, `STO-`, `STOm`, and so on. It is also how
the 284 `UNIT_CONV(...)` rows work: they expand at `items.c:1772-1773` to a row
whose `func` is `fnUnitConvert` and whose `param` is `unit | invert`.

**The categories.** `status & CAT_STATUS` classifies each row
(`defines.h:1054-1066`), 4 bits, twelve defined values:

| category | meaning |
|---|---|
| `CAT_NONE` | none of the others |
| `CAT_FNCT` | a function - the bulk of the table |
| `CAT_MENU` | a menu; its row supplies the label, its `func` is never called |
| `CAT_CNST` | a constant |
| `CAT_FREE` | a reserved spare slot, `func` = `itemToBeCoded` |
| `CAT_REGS` | a register |
| `CAT_RVAR` | a reserved variable |
| `CAT_DUPL` | duplicate of another item - **defined but used zero times** |
| `CAT_SYFL` | a system flag |
| `CAT_AINT` / `CAT_aint` | upper- and lower-case alpha characters |
| `CAT_MNUH` | a hidden menu, reachable only via `XEQ OPENM` |

Do not try to count these with grep. `CAT_[A-Za-z]+` matches inside macro names
such as `ITM_M_CONCAT_OLD`, and 284 rows get their category from the
`UNIT_CONV` macro rather than the row text. As orders of magnitude only: about
a thousand rows are `CAT_FNCT`, about 800 `CAT_NONE`, roughly 150 each of
`CAT_MENU` and `CAT_FREE`, and about a hundred `CAT_SYFL`.

**Unimplemented items fail safely.** `itemToBeCoded()` (`items.c:6-8`) does one
thing: it clears `funcOK`, which makes `runFunction` raise
`ERROR_ITEM_TO_BE_CODED` instead of calling anything. The `CAT_FREE` spares and
every not-yet-written command point at it. `items.h:2978` records the rule:
"Increment LAST_ITEM only when the spares are exhausted."

**The generators stub every command.** Under `-DGENERATE_CATALOGS` or
`-DGENERATE_TESTPGMS`, `items.c` defines an empty body for essentially every
`fn*` in the calculator, so the generators can link the table's data without
linking the implementations. The block is a fifth of the hottest file in the
repository and exists purely to satisfy a linker.
[00-architecture.md](00-architecture.md) s4.1 owns the count and explains why the function
pointer in `item_t` makes it unavoidable.

**`calcMode` is the input state machine.** One global selects who owns the
keyboard (`defines.h:1632-1650`):

```
  CM_NORMAL 0   CM_AIM 1    CM_NIM 2      CM_PEM 3     CM_ASSIGN 4
  CM_REGISTER_BROWSER 5     CM_FLAG_BROWSER 6          CM_FONT_BROWSER 7
  CM_PLOT_STAT 8            CM_ERROR_MESSAGE 9         CM_BUG_ON_SCREEN 10
  CM_CONFIRMATION 11        CM_MIM 12    CM_EIM 13     CM_TIMER 14
  CM_GRAPH 15               CM_ASN_BROWSER 17          CM_LISTXY 18
```

Each mode has an owning file: NIM/AIM in `bufferize.c`, MIM in
`ui/matrixEditor.c`, PEM in `programming/`, the browsers in `browsers/`.
`calcMode.c` performs the transitions. Reading `calcMode` is how shared code
discovers who is in control.

**TAM is not one of these modes.** There is no `CM_TAM`. Parameter entry is a
second, parallel state machine held in `tamState_t tam` (`typeDefinitions.h:672`,
declared `c47.h:451`) and tested as `tam.mode`, whose values are the `TM_*`
constants 10001..10022 (`defines.h:1673-1694`) - a range chosen so it cannot
collide with a `calcMode`. Both are live at once: you are in `CM_NORMAL` *and*
in TAM. `determineItem` checks `tam.mode` before it checks `calcMode`
(`keyboard.c:1675`) and resolves the key through the `primaryTam` column,
ignoring shift.

**Eight of the modes are modal: they save the mode they interrupted and restore
it on exit.** The slot is `previousCalcMode`, written by `fnAssign`
(`assign.c:557`), the four browsers (`registerBrowser.c:172`, `flagBrowser.c:71`,
`fontBrowser.c:102`, `asnBrowser.c:144`), `setConfirmationMode`
(`config.c:1054`), `displayBugScreen` (`error.c:339`) and the graph entry
(`graphs.c:306,309`). Exit assigns `calcMode = previousCalcMode`.

It is **one slot, not a stack**, and no writer checks whether the mode it is
saving is itself a modal one. Open a browser from a confirmation prompt and the
prompt's own restore target is overwritten. The only patch for this is a
special case for the timer at `keyboard.c:3929`, and it covers the browsers
only. Treat "modal over modal" as unsupported rather than as a bug to work
around.

Two mode values are worth knowing for the wrong reasons. `CM_ERROR_MESSAGE` (9)
has **no writer anywhere** - errors set `lastErrorCode` instead (`error.c:277`) -
yet four `switch` arms still handle it. `CM_NO_UNDO` (16) is in no `determineItem`
branch, so a key pressed while `complexSolver()` holds it reaches the bug screen
at `keyboard.c:1688`.

## 6. The data model

**Registers are numbered, and the number decides the kind.** The map is
documented at `defines.h:1183-1206` and defined in the enum below it:

```
  0    - 99     global numbered registers          user
  100  - 111    lettered X Y Z T A B C D L I J K   user
  112  - 117    stat parameters M N P Q R S        user, read by distributions
  118  - 125    spare E F G H O U V W              user, no indirect access
  126  - 134    SAVED_REGISTER_* (UNDO)            not user accessible
  135  - 136    TEMP_REGISTER_1, TEMP_REGISTER_2_SAVED_STATS   not user accessible
  137  - 248    unused
  256  - 1999   named variables
  2000 - 2047   reserved variables
  7000 - 7098   local registers (99, LocR)
```

The RPN stack is the first four or eight lettered registers:
`getStackTop()` is `SSIZE8 ? REGISTER_D : REGISTER_T` (`defines.h:2203`). In
4-level mode A-D are ordinary user registers; in 8-level mode they are stack.
Code that walks the stack must use `getStackTop()`, never `REGISTER_T`.

I, J and K are the matrix index registers as well as user registers. That dual
role is a real source of defects; [04-debugging.md](04-debugging.md) s8.1 records two bugs
found there and the sentinel battery that finds them.

**There are two register numberings, and they are not the same.** A program step
stores a register in **one byte**, so a second enum exists purely for the
keystroke encoding:

| | C (`enum REG_NUMBERS`, `defines.h:1202`) | keystroke (`enum REG_NUMBERS_IN_KS_CODE`, `defines.h:1337`) |
|---|---|---|
| global numbered | 0-99 | 0-99 |
| lettered X..K | 100-111 | 100-111 |
| local `.00`-`.98` | 7000-7098 | 112-210 |
| stat M-S, spare E-W | 112-125 | 211-224 |

The two agree only for 0-111. The bridge is branchless arithmetic:
`regKStoC()` (`defines.h:1414`) and `regCtoKS()` (`defines.h:1422`).
Anything that reads or writes a program byte must convert; anything that touches
`globalRegister[]` must not.

Byte values 249-255 are not registers at all but TAM sentinels
(`defines.h:1384-1393`): `LOCAL_LABEL_VARIABLE` 249, `SYSTEM_FLAG_NUMBER` 250,
`VALUE_0` 251, `VALUE_1` 252, `STRING_LABEL_VARIABLE` 253, `INDIRECT_REGISTER`
254, `INDIRECT_VARIABLE` 255. This is why the local-register block had to move
out of the 0-255 range in the C numbering: 99 locals plus 112 low registers plus
seven sentinels do not fit in a byte any other way.

**A register is 32 bits and holds no value.** `registerHeader_t`
(`typeDefinitions.h:415-424`) is a union over one `uint32_t`:

```c
  unsigned pointerToRegisterData : 16;  // a BLOCK NUMBER, not a pointer
  unsigned dataType              :  4;  // dtLongInteger, dtReal34, ...
  unsigned tag                   :  5;  // angular mode / SI base / long-integer sign
  unsigned readOnly              :  1;
  unsigned notUsed               :  6;
```

The 16-bit block number is the origin of the whole memory design, and the 4-bit
type field is why the type space is full at 16 entries
(`typeDefinitions.h:215`, "4 bits (NOT 5 BITS)"). The 5-bit `tag` is overloaded
per type; a long integer's sign lives there, not in its data.

**Memory is a block pool addressed by those 16-bit indices.** `ram` is a
`uint32_t *` (`c47.h:333`), allocated once (`config.c:1533`). A block is 4
bytes: `BPB` is 2, `BYTES_PER_BLOCK = 1 << BPB` (`defines.h:2208-2209`),
`TO_BLOCKS(n)` rounds up (`defines.h:2210`). `C47_NULL` is 65535
(`defines.h:2213`), so the pool must stay below 65535 blocks:
`RAM_SIZE_IN_BLOCKS` is 16384 on old hardware and 65534 on new
(`defines.h:2048-2055`). `allocC47Blocks` / `freeC47Blocks` (`memory.c:76`,
`memory.c:116`) are accounting shims over `src/c47/core/freeList.c`, a best-fit
free-region allocator with no compaction.

`ram` is one flat array with three tenants:

```
  block 0                                                RAM_SIZE_IN_BLOCKS-1
  |                                                                        |
  +----------------------+---------------------------+-------------------+
  | reserved-variable    | free-list pool            | program memory    |
  | static area, 0..67   | (grows up from block 68)  | (grows DOWNWARD)  |
  +----------------------+---------------------------+-------------------+
```

The reserved-variable area is not allocated: its block offsets are baked into
the `const` table `allReservedVariables[]` (`registers.c:61-109`), and the pool
base is computed from the last of them (`config.c:1544-1545`). Program memory
starts at the last block (`config.c:1577`) and `resizeProgramMemory`
(`memory.c:158-209`) grows it downward by shrinking the topmost free region,
which works only because the region array is address-sorted.

A register's value therefore lives in a pool block, and `reallocateRegister`
resizes it when the type or size changes. Two consequences a maintainer must
know:

- **A data block's size is recoverable only by reading the block itself** -
  a string's or long integer's length is in its own first block, a matrix's
  dimensions in its own header (`registers.c:1154-1192`). Corrupt one and the
  next free passes a wrong size to the allocator.
- An over-long write inside the pool is invisible to ASan and valgrind, because
  the pool is one `malloc`. That is why [04-debugging.md](04-debugging.md) s13 exists.

**GMP does not use the pool.** `allocGmp` rounds to block size for accounting
and then calls libc `malloc`; the `freeListAlloc` call is commented out
(`memory.c:130-136`), hooked in via `mp_set_memory_functions` (`c47.c:609`).
`c47MemInBlocks` and `gmpMemInBytes` track two disjoint heaps, and
`getFreeRamMemory()` reports only the pool. Long integers therefore consume host
heap that the pool's own accounting cannot see.

**Types dispatch through 10x10 tables.**
`NUMBER_OF_DATA_TYPES_FOR_CALCULATIONS` is 10 (`defines.h:1559`). The four
arithmetic operations are matrices of function pointers indexed by the types of
X and Y, declared in `c47.h:278-281` and defined in
`mathematics/addition.c:10` and its siblings, marked `TO_QSPI` so they land in
DM42 flash. `addition[dtA][dtB]()` is the whole of operator dispatch: there is no
switch forest.

### 6.1 Ownership, and the ways it goes wrong

The pool stores no allocation header, so **the caller is the authority on size**:
`freeC47Blocks(ptr, sizeInBlocks)` trusts the size it is handed
(`memory.c:116`), and `freeRegisterData` recomputes that size from the register's
*current* header (`defines.h:2204`). Change a register's type, string length or
matrix dimensions before freeing it and the wrong number of blocks is returned.
The mismatch detector is compiled out on the DM42, so on hardware the free list
is corrupted silently.

`reallocC47Blocks` **always moves** - it allocates, copies, frees
(`freeList.c:89-93`); there is no in-place growth. Three consequences a newcomer
meets in this order:

- **A linked matrix dies when its register is resized.** `linkTo*MatrixRegister`
  points `matrixElements` straight into the register's pool block. Anything that
  calls `reallocateRegister` frees that block (`registers.c:2035`) and the
  best-fit allocator hands it to the next caller immediately. `matrix.h:309-311`
  warns about this for `redimMatrixRegister` and `appendRowAtMatrixRegister` -
  but it is true of every path through `reallocateRegister`, including
  `initMatrixRegister`, `copySourceRegisterToDestRegister` and `clearRegister`.
- **Owned and borrowed matrices look identical.** `realMatrixInit` allocates and
  the caller must free; `linkTo*MatrixRegister` borrows and the caller must not.
  Both produce a `real34Matrix_t`. `realMatrixFree` frees unconditionally
  (`matrix.c:2028`), so calling it on a linked matrix frees the register's
  payload out from under the register.
- **Adding a named variable moves the table.** `allNamedVariables` is itself
  pool-allocated and grown one entry at a time (`registers.c:862`), so any
  pointer into it is stale afterwards. The same applies to `currentLocalRegisters`
  across `allocateLocalRegisters`, which is why that function re-derives its own
  pointers and re-links the frame.

The rule underneath all four: **never cache a pointer derived from a register
across an allocation.** Every `REGISTER_*` accessor re-resolves through the
header on each use, and that is the contract, not an inefficiency.

## 7. The calculator's state

There is no state object. The calculator's state is ~312 mutable globals
declared in `c47.h` (345 `extern` declarations in total) and visible to all 228
translation units - see [00-architecture.md](00-architecture.md) s3 for what that costs. What
follows is where the state that matters actually lives.

### The value state

| what | global | declared |
|---|---|---|
| registers 0-136 | `globalRegister[NUMBER_OF_GLOBAL_REGISTERS]` | `c47.h:350` |
| named variables 256-1999 | `allNamedVariables` (pointer into the pool) | `c47.h:336` |
| local registers 7000-7098 | `currentLocalRegisters` (behind the subroutine header) | `c47.h:347` |
| reserved variables 2000-2047 | `allReservedVariables[]`, a `const` table + fixed pool blocks | `registers.c:61` |
| the pool | `ram`, `freeMemoryRegions[MAX_FREE_REGIONS]` (50 on DMCP, 200 elsewhere) | `c47.h:333`, `:351` |
| the indexed matrix | `matrixIndex` (+ registers I/J as the cursor) | `c47.h:276` |
| statistical sums | `statisticalSumsPointer` (28 sums at 75 digits) | `c47.h:331` |

The RPN stack is not a separate structure: it is
`globalRegister[REGISTER_X .. getStackTop()]`. Stack operations move 32-bit
descriptors, not data - `liftStack` shifts headers and frees the one that falls
off the top.

### The engine state

| what | global | declared |
|---|---|---|
| system flags | `systemFlags0` (a 64-bit word; `systemFlags1` follows) | `c47.h:576` |
| local flags | `currentLocalFlags` (32 per subroutine level) | `c47.h:334` |
| undo | `thereIsSomethingToUndo` + `SAVED_REGISTER_*` (126-134) | `c47.c:51` |
| last function | `lastFunc`, `lastParam` | `c47.c:11-12` |
| error | `lastErrorCode`, `errorMessageRegisterLine` | `c47.h:433` |
| transient display note | `temporaryInformation` | `c47.h:435` |
| solver | `currentSolverStatus` (a bitfield: formula vs program, ready flags) | `c47.h:536` |

`lastErrorCode` is the error channel: functions return `void` and set the
global. It is cleared not by the caller but by the **next refresh**, together
with `temporaryInformation` (`screen.c:2127-2131`) - that coupling is the only
normal path that resets it.

### The programming state

| what | global | declared |
|---|---|---|
| program memory | `beginOfProgramMemory`, `firstFreeProgramByte`, `freeProgramBytes` | `c47.h:444`, `:445`, `:520` |
| the label index | `labelList` (rebuilt by `scanLabelsAndPrograms`) | `c47.h:362` |
| the program index | `programList` | `c47.h:364` |
| the edit/run cursor | `currentStep`, `programListEnd`, `pemCursorIsZerothStep` | `c47.h:372`, `c47.c:53-54` |
| run state | `programRunStop` (`PGM_STOPPED`/`PGM_RUNNING`/`PGM_WAITING`/`PGM_SINGLE_STEP`) | `c47.h:438` |
| the return stack | `currentSubroutineLevelData` - a linked list in the pool | `c47.h:330` |

`labelList` and `programList` are **derived state**: they are rebuilt from the
program bytes by `scanLabelsAndPrograms()` after any edit, load or restore. The
program bytes are the source of truth; the indices are a cache.

### The UI state

| what | global | declared |
|---|---|---|
| the mode | `calcMode` | `c47.h:418` |
| shift | `shiftF`, `shiftG` (+ `lastshiftF`/`lastshiftG` snapshots) | `c47.c:44-47` |
| the menu stack | `softmenuStack[SOFTMENU_STACK_SIZE]`, depth 8, no stack pointer | `c47.h:337` |
| pending argument | `tam` (a `tamState_t`; `tam.mode != 0` means TAM is active) | `c47.h:451` |
| the input buffer | `aimBuffer` - **NIM and AIM share it** | `c47.h:377` |
| user key layout | `kbd_usr[37]` (persisted); `kbd_std` is a `calcModel` macro over `const` tables | `c47.h:343` |
| the frame buffer | `lcd_buffer` (240 rows x 52 bytes) | `c47.h:239` |
| refresh budget | `screenUpdatingMode` (a suppression bitmask) | `c47.h:443` |

Two of these carry more weight than their size suggests. `calcMode` decides who
owns the keyboard, so almost every input path begins `switch(calcMode)`. And
`tam.mode` is the whole of "a command is waiting for its argument".

### What persists

`.s47` state carries the register file, program memory, flags, `kbd_usr` and
`matrixIndex`. `backup.cfg` is simulator-only and model-conditional
(`saveRestoreBackup.c:27`).

Notably **`calcMode` is not persisted** - only `calcModel` (the hardware/keymap
model) is. A power cycle cannot resume inside the matrix editor or PEM. The
derived indices (`labelList`, `programList`) are not persisted either; they are
rebuilt on load.

## 8. The HAL and portability

`src/c47/hal/` is five headers and no implementation: `audio.h`, `gui.h`,
`io.h`, `lcd.h`, `print_ir.h`, 497 lines. Four adapter sets implement them:

```
  src/c47-gtk/hal/    audio.c gui.c io.c lcd.c print_ir.c
  src/testSuite/hal/  audio.c gui.c io.c lcd.c print_ir.c
  src/c47-dmcp/hal/   audio.c io.c print_ir.c (+ console.c)
  src/c47-dmcp5/hal/  audio.c io.c print_ir.c (+ console.c)
```

The library calls the contract, not the platform: the save/restore files call
`ioFileOpen`, which exists only in the adapters. This is what makes the testSuite
possible - it runs the whole calculator with no window and no hardware.

**All drawing funnels through one function.** The screen is 400x240
(`defines.h:1444-1445`), 1 bit per pixel, and every pixel primitive is a
`static inline` wrapper over `bitblt24` in `hal/lcd.h`:

```c
  static inline void setBlackPixel(uint32_t x, uint32_t y) { bitblt24(x, 1, y, 1, BLT_OR,   BLT_NONE); }
  static inline void setWhitePixel(uint32_t x, uint32_t y) { bitblt24(x, 1, y, 1, BLT_ANDN, BLT_NONE); }
  static inline void flipPixel    (uint32_t x, uint32_t y) { bitblt24(x, 1, y, 1, BLT_XOR,  BLT_NONE); }
```

The shared frame buffer is `lcd_buffer` (`c47.h:239`), laid out as the DM42
hardware lays it out: 240 rows of 52 bytes, being a dirty flag, a row number,
and 50 bytes = 400 bits. On DMCP it is bound to the SDK's own buffer
(`c47.c:617`); on GTK it is host memory and `LCD_write_line` expands 1bpp to a
32-bit RGB24 surface that cairo draws. `screenData` is `PC_BUILD`-only - the
32-bit surface is a simulator artefact.

Note the input lines overlay the register lines rather than having their own
space: `Y_POSITION_OF_NIM_LINE` equals `Y_POSITION_OF_REGISTER_X_LINE`, and
`Y_POSITION_OF_TAM_LINE` equals `Y_POSITION_OF_REGISTER_T_LINE`
(`defines.h:1436-1438`). Refresh is budgeted, not unconditional:
`screenUpdatingMode` is a bitmask that lets callers suppress regions, and
`_refreshNormalScreen` early-exits when it is not `SCRUPD_AUTO`.

Two qualifications matter when reading the code, both measured in
[00-architecture.md](00-architecture.md) s5 and s6:

- The HAL contract is the DM42 vendor's API (`hal/lcd.h:29-31` names
  `lcd_fill_rect`, `lcd_refresh`, `LCD_write_line` "from dmcp.h"). On DMCP the
  SDK provides them and no adapter is needed; every other target emulates the
  DM42.
- The HAL is not the portability layer. `PC_BUILD` and `DMCP_BUILD` conditionals
  are, and there are far more of them than there is HAL. Only one branch is
  compiled at a time, which is why CI building every target is load-bearing.

## 9. Subsystem map

| directory | holds | reached from |
|---|---|---|
| `src/c47` (root) | display, input, state, persistence, dispatch | everywhere |
| `mathematics/` | arithmetic, transcendental, matrix, prime, high-precision `xfn` | the item table; the 10x10 type tables |
| `distributions/` | statistical distributions | item table; read stat registers M-S |
| `logicalOps/` | and/or/xor/not/masks/bit rotation on short integers | item table |
| `solver/` | `solve`, `integrate`, `differentiate`, `graph`, `tvm`, `sumprod`, `equation` | item table; calls user programs and equations |
| `programming/` | decode, label scan, GTO/XEQ, next step, PEM, programmable menus | keyboard, item table |
| `ui/` | matrix editor, TAM parameter entry, tone | keyboard, via `calcMode` |
| `browsers/` | register, flag, font and assignment browsers | keyboard, via `calcMode` |
| `printing/` | IR printer output and its fonts | item table |
| `core/` | `freeList` allocator | `memory.c` |
| `hal/` | five platform contracts | the library; implemented per target |
| `c47Extensions/` | C47 additions over the inherited WP43 core: `addons`, `graphs`, `graphText`, `jm`, `keyboardTweak`, `radioButtonCatalog`, `textfiles`, `xeqm`, `inlineTest` | item table, keyboard |

### 9.1 Inside the subsystems

`mathematics/` - 128 `.c` + 129 `.h`, more files than the rest of the library
put together, and comparatively cold. The layout is mostly one operation per
file, a WP43 inheritance rather than a C47 decision: the median `.c` is 107
lines and 70 of the 128 are under 120. But "one function per file" is not a rule
the directory keeps. Six files hold most of the mass:

```
  matrix.c    9542      elliptic.c  1828
  prime.c     2383      division.c  1515
  wp34s.c     2344      xfn.c       1146
```

`matrix.c` alone is 21% of the directory and is the only mathematics file in the
repository's top ten by churn. `xfn.c` is the 1071-digit extended-precision
engine that owns six registers as two triples (Section 7). `wp34s.c` carries
routines inherited from the WP34S engine.

`distributions/` - 16 distributions, each a `.c`/`.h` pair:

```
  binomial  cauchy   chi2      exponential  f        geometric  gev     hyper
  logistic  negBinom normal    pareto       poisson  t          uniform weibull
```

They read their parameters from the stat registers M-S, which is why storing
your own data there silently feeds garbage to them (Section 6).

`logicalOps/` - 11 operations on short integers, one pair each: `and`, `or`,
`xor`, `nand`, `nor`, `xnor`, `not`, `mask`, `countBits`, `rotateBits`,
`setClearFlipBits`.

`solver/` - `solve` (Brent, optionally Newton), `integrate` (double-exponential
tanh-sinh, not Romberg), `differentiate` (finite-difference stencils), `graph`,
`tvm`, `sumprod`, `isumprod`, `equation`, plus `finite_differences.h`.

`programming/` - `decode`, `lblGtoXeq`, `manage`, `nextStep`, `input`, `clcvar`,
`programmableMenu`.

`browsers/` - `registerBrowser`, `flagBrowser`, `fontBrowser`, `asnBrowser`.

`printing/` - `print` plus two font-data files (`martelFonts`, `printerFont8`).

`ui/` - `matrixEditor`, `tam`, `tone`. `core/` - `freeList`. `hal/` - five
headers, no `.c`.

`c47Extensions/` is the fork seam. It holds the fork's additive layer, kept out of the
WP43-inherited core so upstream merges stay tractable; its header still reads
`Copyright The WP43 and C47 Authors` (`c47Extensions.h:2`). The split is visible
in the grapher: the rendering and plot-mode half is `c47Extensions/graphs.c`,
while the sampling and solver engine stayed in the inherited `solver/graph.c`.
It is 19 files and 9813 lines, and `addons.c` is among the hottest files in the
repository.

**How the solver family calls user code.** Values are passed in registers, not
arguments. Every engine - `solve`, `integrate`, `differentiate`, `sumprod`,
`graph` - does the same four steps: put the trial value in `REGISTER_X`, call
`fnFillStack` so the callee sees it throughout the stack, branch on
`currentSolverStatus & SOLVER_STATUS_USES_FORMULA` to either `parseEquation(...)`
or `execProgram(<label>)` (`programming/lblGtoXeq.h:31`), then read the result
back out of `REGISTER_X` with `lastErrorCode` as the error channel. There is no
general `execute_rpn_function`: the one function of that name is the grapher's
own sampler (`solver/graph.c:77`), private to that file.

## 10. Control flow: a key press to a screen

```
  GTK button / DMCP key
        |
        v  btnPressed                                          keyboard.c:1800
  determineItem(key)    resolve shift, pick a field of calcKey_t  keyboard.c:1533
        |                kbd_usr[] if FLAG_USER else kbd_std (a calcModel macro)
        |                AIM  -> primaryAim / fShiftedAim / gShiftedAim
        |                TAM  -> primaryTam            (no shift in TAM)
        |                else -> primary / fShifted / gShifted
        v
  item number
        |
        +--> processKeyAction(item)   mode-specific interception only  keyboard.c:2360
        |      calcMode owns it? -> bufferize.c (NIM/AIM) | ui/tam.c (TAM)
        |                           ui/matrixEditor.c (MIM) | programming/ (PEM)
        |
        v  (ON KEY RELEASE)  btnReleased -> executeFunction     keyboard.c:2057, :929
  runFunction(item)                                                 items.c:631
        |  param in TM_VALUE..TM_CMP ? -> tamEnterMode(); return    items.c:689
        |     ... later ... tamProcessInput() -> reallyRunFunction(op, value)
        |  calcMode == CM_PEM ? -> addStepInProgram(item)        items.c:718-756
        v
  reallyRunFunction(item, param)   saveForUndo, hourglass, lastFunc  items.c:237
        v
  indexOfItems[item].func(param)   THE indirect call                 items.c:402
        |
        v
  the command           registers.c / stack.c / mathematics/...
        |                operator dispatch: addition[typeX][typeY]()
        v
  refreshScreen(source) switch(calcMode) -> _refreshNormalScreen    screen.c:5993
        v
  setBlackPixel -> bitblt24(...)   the single drawing choke point   hal/lcd.h:121
        v
  lcd_buffer -> hal/lcd.h -> the platform adapter
```

Three things surprise most readers:

- **Most items execute on key release, not press.** `processKeyAction` only
  intercepts mode-specific input; the general path is `btnReleased` ->
  `executeFunction` -> `runFunction`. Long-press works because of this.
- **An item "takes an argument" purely by its `param` field.** If
  `indexOfItems[func].param` falls in `TM_VALUE..TM_CMP` (`defines.h:1673-1694`),
  `runFunction` diverts to `tamEnterMode` and returns; the argument arrives via
  later keys resolved through `primaryTam`, and TAM finally calls
  `reallyRunFunction` directly, bypassing `runFunction` so it cannot re-enter
  TAM.
- **In PEM most items are recorded, not run.** `runFunction` calls
  `addStepInProgram(func)` instead of executing, subject to an exception list.

### 10.1 What the diagram cannot show

**The item survives the press only in a global.** `showFunctionName` stores it -
`showFunctionNameItem = item` (`screen.c:2097`) - and `btnReleased` reads it back
(`keyboard.c:2137-2138`). Nothing else carries the item between the two halves of
a key press, so anything that clears that global mid-press cancels the command.

**Digits are the exception: they act on press.** `processKeyAction` consumes
`ITM_0`..`ITM_9`, `ITM_PERIOD` and `ITM_EXPONENT` immediately and sets
`keyActionProcessed` (`keyboard.c:2803`), so they never reach the release path.
Every other item defers. Typing is therefore a different code path from
commanding, not a special case of it.

**The stack lifts when number entry opens, not when it closes.** `calcModeNim`
calls `liftStack()` and then zeroes X (`calcMode.c:269`), so the display already
shows a pushed stack while you are still typing. `closeNim` re-arms the *next*
lift with `setSystemFlag(FLAG_ASLIFT)` as its first statement
(`bufferize.c:2344`). That is why ENTER, which clears `FLAG_ASLIFT`, makes the
following digits overwrite X instead of pushing.

**Errors are polled, never returned.** No function in the dispatch chain returns
a status. `displayCalcErrorMessage` sets `lastErrorCode`, and each layer tests it
afterwards: `reallyRunFunction` undoes the operation (`items.c:581`), and
`runProgram` breaks out of its loop without advancing the step
(`lblGtoXeq.c:919`), which is why a stopped program rests on the offending line.

**The next key press clears the error and executes.** Any item except EXIT and
BACKSPACE zeroes `lastErrorCode` on the way in (`keyboard.c:2368`), so dismissing
an error and acting on it are the same keystroke - there is no acknowledge step.

**`refreshScreen` is not a pure renderer and not idempotent.** It pushes
softmenus, can write `calcMode`, and on exit latches
`SCRUPD_MANUAL_STATUSBAR | SCRUPD_MANUAL_STACK | SCRUPD_MANUAL_MENU`
(`screen.c:5965`), so an immediate second call is close to a no-op until
something clears those bits. Register lines are drawn T, Z, Y, X in that order
and the order is load-bearing.

The corpus bypasses the top of this: it calls `runFunction` directly with a
declared input state, which is why it tests computation and not presentation.
`t47` enters at the same point through a Jim/Tcl DSL. Only the GTK simulator
under xvfb exercises the keyboard and menu layer, which is why
[04-debugging.md](04-debugging.md) s9 exists.

A user program enters at the same place. Programs are a raw byte array at the
top of `ram` (Section 6), encoded as item numbers: one byte below 128, otherwise
two, `(itm>>8)|0x80` then `itm&0xff`, capping the encodable item at 0x7fff.
`.END.` is the two-byte sequence `255,255`. Running a step decodes the item and
calls `runFunction`, so a program step and a key press converge on the same
dispatch. `scanLabelsAndPrograms()` (`programming/manage.c:102-194`) rebuilds
the label index after any edit or load.

The return stack is not fixed-depth: XEQ pushes a `subroutineLevelHeader_t` into
the block pool as a doubly-linked list (`typeDefinitions.h:464-474`), so nesting
is bounded by free RAM and exhaustion raises `ERROR_RAM_FULL`
(`lblGtoXeq.c:191-196`). `LocR` appends local flags and registers behind that
header in place (`registers.c:565-585`), which is why local registers are numbered
7000-7098 rather than living in `globalRegister[]`.

## 11. How the parts connect

Two mechanisms carry almost all of the coupling.

**The item table.** Everything that can invoke a command addresses it by item
number and nothing else: `keyboard.c` for keys, `softmenus.c` for menus,
`programming/` for program steps, `ui/tam.c` when an argument completes, and the
testSuite corpus and the t47 DSL for tests. None of them names a function.
`items.c` then dispatches to 205 of the 229 library files.

**The type tables.** `addition[][]` and its three siblings connect every
arithmetic entry point to every numeric type implementation, indexed by the data
types of X and Y. There is no switch forest.

Both are good design, and both are why the codebase is one knot. Because
`item_t.func` is a function pointer, linking the table links the calculator.
Every command calls back into `items.c`, `registers.c`, `flags.c` and `error.c`,
so the fan-out returns. And the base services call upward: `flags.c` and
`error.c` notify the UI directly, so the bottom of the graph reaches the top.

The resulting dependency graph - one strongly connected component of 222 of 228
link units - is measured in [00-architecture.md](00-architecture.md) s8, which also
sets out which edges close the cycle and what each would cost to cut. Read it
before proposing any structural change - but note that its Sections 9 to 11 are
assessment and an unadopted proposal, not an upstream plan.

## 12. Runtime resources

`res/` ships with the application and several entries are load-bearing at run
time, not decoration:

- `res/c47_pre.css` - the GTK simulator calls `exit(1)` if it cannot open this,
  and the path is cwd-relative. The simulator must be run from the repository
  root.
- `res/PROGRAMS/` - `.p47` keystroke programs plus `.rtf` human-readable exports.
- `res/STATE/`, `res/DATA/` - saved state and data files.
- `res/testPgms/testPgms.bin` - a fixture the corpus needs; its absence fakes a
  dead program engine ([04-debugging.md](04-debugging.md) s11).
- `res/keymaps/`, `res/fonts/`, `res/offimg/`, `res/tone/`, `res/dmcp/`,
  `res/dmcp5/`, `res/combo/`.
- `res/SCRIPTS/` - the t47 DSL's own reference, `cli_automation_examples.txt`.
  Read it before writing a script ([03-testing.md](03-testing.md) Section 2).

File formats and paths are declared in one place, `src/c47/hal/io.h`: `.s47`
state in `STATE/` (`io.h:11-12`), `.d47` data in `DATA/` (`io.h:14-15`), `.p47`
programs in `PROGRAMS/` with `ALLPGMS/` for bulk export (`io.h:17-20`), `.txt`
and `.rtf` human-readable exports (`io.h:21-22`), `SAVFILES/C47.sav` (`io.h:24-31`),
`LIBRARY/C47.dat` (`io.h:33-34`). `.p47` is plain ASCII: one decimal byte per
line after a six-line header.

The I/O HAL allows **a single open file at a time** (`io.h:85-87`) - 16 abstract
paths (`io.h:51-67`) and one `ioFileOpen`/`Write`/`Read`/`Seek`/`Close` set
(`io.h:92-126`). `backup.cfg` is simulator-only and model-conditional
(`saveRestoreBackup.c:27`).

## 13. Risks and open points

- **The spreadsheet inputs.** Keyboard layout, CONFIG defaults, unit conversions
  and item indices have their design source of truth in binary `.xlsx` under
  `src/index spreadsheet/`. Provenance is not diffable, and CI builds xlsxio from
  source to read one of them. Two filenames carry their own staleness warnings.
- **`src/generated/` shadowing.** The include path prefers a gitignored,
  locally-populated directory. Any claim about generated headers must state
  whether the tree was refreshed.
- **One branch is compiled at a time.** `PC_BUILD` and `DMCP_BUILD` code is not
  type-checked by the other target's build. Only CI compiling every target
  catches that.
- **Presentation is untested.** The corpus asserts computed values. Everything
  reached through `screen.c`, `display.c`, `statusBar.c` and `softmenus.c` is
  verified by human inspection.
- **Not verified here.** This page was written from static reads of the tree at
  `33328e4cc`; no build was executed for it. The subsystem responsibilities in
  Section 9 are from directory contents and call sites, not from an exhaustive
  read of all 229 library files.

## References checked

- Upstream c43 `master` at `33328e4cc25588eb7504f38f4076f8feae3ae766`,
  2026-07-18: `README.md`, `BUILD.md`, `Makefile`, `meson.build`,
  `meson_options.txt`, `.gitignore`, `.gitlab-ci.yml`, `src/c47/c47.h`,
  `src/c47/c47.c`, `src/c47/defines.h`, `src/c47/typeDefinitions.h`,
  `src/c47/items.h`, `src/c47/memory.c`, `src/c47/config.c`,
  `src/c47/registers.c`, `src/c47/core/freeList.c`, `src/c47/hal/io.h`,
  `src/c47/saveRestoreBackup.c`, `src/c47/programming/manage.c`,
  `src/c47/programming/lblGtoXeq.c`, `src/c47/solver/graph.c`,
  `src/c47/c47Extensions/c47Extensions.h`, `src/c47/ui/matrixEditor.c`,
  `src/c47/mathematics/addition.c`, `src/c47/meson.build`,
  `src/c47-gtk/meson.build`, `src/c47-dmcp/meson.build`,
  `src/c47-dmcp5/meson.build`, `src/ttf2RasterFonts/ttf2RasterFonts.c`,
  `src/generateCatalogs/meson.build`, `src/testSuite/meson.build`,
  `src/t47/meson.build`, `dep/meson.build`, `subprojects/gmp-6.2.1.wrap`.
- [00-architecture.md](00-architecture.md), for the physical architecture. It
  analysed `d969ec75db`; its headline figures were reproduced at `33328e4cc`.
- [02-build.md](02-build.md), [04-debugging.md](04-debugging.md).
- Upstream `docs/appnotes/sources/AN0025_C47_R47_JM_d47_file_format_2026-07-13.txt` is the
  first-party spec for the `.d47` record layout. Not read for this page; read it
  before documenting that format.

